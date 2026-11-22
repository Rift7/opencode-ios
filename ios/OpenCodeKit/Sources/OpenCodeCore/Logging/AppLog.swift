import Foundation
import OSLog

/// Log categories, one per area the app reports on. Values are stable because diagnostics and
/// console filters key off them.
public enum AppLogCategory: String, CaseIterable, Sendable {
  case send
  case network
  case stream
  case voice
  case app
  case perf
}

/// Fixed event names. A log line always starts with one of these, so the public part of a message
/// is static text the codebase controls.
public enum LogEvent: String, Sendable, CaseIterable {
  case launchStarted = "launch.started"
  case launchFailed = "launch.failed"
  case probeStarted = "probe.started"
  case probeFinished = "probe.finished"
  case linkProbe = "link.probe"
  case connectionAttempt = "connection.attempt"
  case connectionReady = "connection.ready"
  case connectionFailed = "connection.failed"
  case transportBlocked = "transport.blocked"
  case screenShown = "screen.shown"
  case networkResponse = "network.response"
  case networkFailed = "network.failed"
  case networkRetried = "network.retried"
  case streamConnected = "stream.connected"
  case streamDisconnected = "stream.disconnected"
  case streamOverflow = "stream.overflow"
  case streamResynchronized = "stream.resynchronized"
  case pairingDecoded = "pairing.decoded"
  case pairingRejected = "pairing.rejected"
  case pairingRedeemed = "pairing.redeemed"
}

/// The only values that may be published with public visibility: numbers and booleans. There is no
/// string case, so a credential, path, address or message body cannot be passed as a public value.
public enum LogValue: Sendable, Equatable {
  case count(Int)
  case status(Int)
  case durationMilliseconds(Int)
  case flag(Bool)

  var rendered: String {
    switch self {
    case .count(let value): "\(value)"
    case .status(let value): "\(value)"
    case .durationMilliseconds(let value): "\(value)ms"
    case .flag(let value): value ? "true" : "false"
    }
  }
}

/// A named public value. The name is a `StaticString`, so it is fixed at the call site and cannot
/// carry runtime data.
public struct LogField: Sendable {
  public let name: StaticString
  public let value: LogValue

  public init(_ name: StaticString, _ value: LogValue) {
    self.name = name
    self.value = value
  }
}

/// Free-form text is recorded only as a private field. OSLog keeps private fields out of the
/// publicly visible stream; they still travel in a sysdiagnose, so do not pass secrets here either.
public struct LogPrivateField: Sendable {
  public let name: StaticString
  public let text: String

  public init(_ name: StaticString, _ text: String) {
    self.name = name
    self.text = text
  }
}

/// One structured log record. `publicText` is the exact string published with public visibility and
/// is assembled only from `LogEvent` and `LogField`, never from caller-supplied text.
public struct LogRecord: Sendable {
  public let event: LogEvent
  public let fields: [LogField]
  public let privateFields: [LogPrivateField]

  public init(event: LogEvent, fields: [LogField] = [], privateFields: [LogPrivateField] = []) {
    self.event = event
    self.fields = fields
    self.privateFields = privateFields
  }

  public var publicText: String {
    var parts = [event.rawValue]
    for field in fields.sorted(by: { String(describing: $0.name) < String(describing: $1.name) }) {
      parts.append("\(field.name)=\(field.value.rendered)")
    }
    return parts.joined(separator: " ")
  }
}

/// Logger facade. Public output is structured and numeric; anything free-form is emitted with
/// private visibility. There is deliberately no API that publishes an arbitrary string.
public struct AppLog: Sendable {
  public static let subsystem = "ai.opencode.migration"

  private let logger: Logger

  public init(category: AppLogCategory) {
    logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
  }

  public func log(_ record: LogRecord) {
    logger.info("\(record.publicText, privacy: .public)")
    for field in record.privateFields {
      logger.debug("\(field.name, privacy: .public)=\(field.text, privacy: .private)")
    }
  }

  public func event(_ event: LogEvent, _ fields: [LogField] = []) {
    log(LogRecord(event: event, fields: fields))
  }

  public func note(_ event: LogEvent, _ name: StaticString, _ text: String) {
    log(LogRecord(event: event, privateFields: [LogPrivateField(name, text)]))
  }
}
