import Foundation
import OpenCodeCore

/// How a request failed before any HTTP status arrived.
public enum TransportFailure: String, Sendable, Equatable, CaseIterable {
  /// No connection was ever made: the server cannot have seen it.
  case notSent
  /// The connection broke after the request may have reached the server.
  case interrupted
  /// No answer in time; the server may still be working on it.
  case timedOut
}

/// The one error every client call throws. Copy is produced from `ServerCopy` at the edge; the
/// value carries typed facts only, so nothing here can leak a credential or an address into a log.
public struct OpenCodeClientError: Error, Equatable, Sendable {
  public enum Failure: Equatable, Sendable {
    case status(Int)
    /// No HTTP status arrived.
    case transport(TransportFailure)
    /// The address itself is not usable.
    case invalidURL
    /// The server predates the route; callers hide the feature rather than retry.
    case unsupported
    /// The body did not match the current contract.
    case undecodable(feature: String)
    /// A 2xx carried a web page instead of API data: this server does not expose the V2 API at
    /// that address. Distinct from a decode mismatch and from authentication/connectivity failures.
    case incompatibleAPI(feature: String)
    /// A request that got no answer and could not be classified further.
    case unreachable
    /// The event stream reached end of input without the server closing it deliberately.
    case streamEnded
    /// The server reported a failed request as an SSE frame (`_tag`).
    case streamServerFailure
    /// One SSE frame passed the 16 MiB bound.
    case streamOversizedFrame
    /// The event consumer fell behind; the rest of the connection is incomplete.
    case streamOverflow
    /// The pairing code was expired or already used (the connect route answered 401).
    case pairingExpired
    /// The server predates pairing links (the connect route answered 404).
    case pairingUnsupported
  }

  public var failure: Failure
  /// Seconds the server asked to wait before trying again (`Retry-After`).
  public var retryAfter: Duration?
  /// How many times the request was sent before this error ended it.
  public var attempts: Int
  /// An earlier attempt failed after it may have reached the server.
  public var earlierAttemptMayHaveArrived: Bool
  /// The request answered `LocationNotFoundError`: the folder it is scoped to is gone.
  public var isLocationMissing: Bool

  public init(
    _ failure: Failure,
    retryAfter: Duration? = nil,
    attempts: Int = 1,
    earlierAttemptMayHaveArrived: Bool = false,
    isLocationMissing: Bool = false
  ) {
    self.failure = failure
    self.retryAfter = retryAfter
    self.attempts = attempts
    self.earlierAttemptMayHaveArrived = earlierAttemptMayHaveArrived
    self.isLocationMissing = isLocationMissing
  }

  public var statusCode: Int? {
    switch failure {
    case .status(let code): return code
    case .pairingExpired: return 401
    case .pairingUnsupported: return 404
    default: return nil
    }
  }

  public var transport: TransportFailure? {
    if case .transport(let failure) = failure { return failure }
    return nil
  }

  public var isUnsupported: Bool {
    failure == .unsupported
  }

  /// A 404 whose body is the server's tagged `LocationNotFoundError`.
  public static func isLocationMissing(status: Int, body: Data) -> Bool {
    guard status == 404, let value = try? JSONDecoder().decode(JSONValue.self, from: body) else {
      return false
    }
    return value["_tag"]?.stringValue == "LocationNotFoundError"
  }

  /// Whether the request may have been carried out though no success came back.
  public var mayHaveReachedServer: Bool {
    if earlierAttemptMayHaveArrived { return true }
    if let transport { return transport != .notSent }
    if let statusCode { return Self.isGatewayFailure(statusCode) }
    return false
  }

  /// Status and transport only: never a message, header or address.
  public var logSummary: String {
    var parts: [String] = []
    if let statusCode { parts.append("HTTP \(statusCode)") }
    if let transport { parts.append("transport \(transport.rawValue)") }
    if isUnsupported { parts.append("unsupported") }
    if case .undecodable(let feature) = failure { parts.append("undecodable \(feature)") }
    if case .incompatibleAPI(let feature) = failure { parts.append("incompatible API \(feature)") }
    if parts.isEmpty { parts.append("client error") }
    if attempts > 1 { parts.append("after \(attempts) attempts") }
    return parts.joined(separator: ", ")
  }

  /// A proxy in front of the server could not get an answer: 502 and 504, and Cloudflare's origin
  /// errors (520–527 and 530).
  public static func isGatewayFailure(_ status: Int) -> Bool {
    status == 502 || status == 504 || (520...527).contains(status) || status == 530
  }

  /// A `Retry-After` value: seconds, or an HTTP date.
  public static func retryAfter(header: String?, now: Date = Date()) -> Duration? {
    guard let text = header?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    if let seconds = Double(text), seconds.isFinite {
      return .seconds(max(0, seconds))
    }
    guard let date = httpDate(text) else { return nil }
    return .seconds(max(0, date.timeIntervalSince(now)))
  }

  private static func httpDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: text) { return date }
    formatter.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss zzz"
    return formatter.date(from: text)
  }

  /// The `LocationNotFoundError` copy, kept beside the type that raises it.
  public static let folderGone = ServerCopy.folderGone
}

/// URLError classification, matching the audited `TransportFailure.ofUrlErrorCode`.
extension TransportFailure {
  /// Nil for cancellation and failures sending again will not change.
  public init?(_ error: any Error) {
    if error is CancellationError { return nil }
    guard let urlError = error as? URLError else { return nil }
    switch urlError.code {
    case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
      .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed:
      self = .notSent
    case .networkConnectionLost, .badServerResponse, .cannotParseResponse, .resourceUnavailable,
      .zeroByteResource, .requestBodyStreamExhausted, .backgroundSessionWasDisconnected:
      self = .interrupted
    case .timedOut:
      self = .timedOut
    default:
      return nil
    }
  }
}
