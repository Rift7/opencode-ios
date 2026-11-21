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

/// Strips values that must never reach a log: credentials, addresses, message bodies and file
/// contents. Call sites log identifiers, counts, lengths, statuses and durations instead.
public enum LogRedactor {
  public static func redact(_ text: String) -> String {
    var value = text
    value = replacing(URLPattern, in: value)
    value = replacing(EmailPattern, in: value)
    value = replacing(TokenPattern, in: value)
    return value
  }

  public static func redact(_ text: String, keepingPrefix prefix: Int) -> String {
    guard text.count > prefix else { return "<redacted>" }
    return String(text.prefix(prefix)) + "…<redacted>"
  }

  private static let URLPattern = try! NSRegularExpression(
    pattern: #"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"']+"#
  )
  private static let EmailPattern = try! NSRegularExpression(
    pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#
  )
  private static let TokenPattern = try! NSRegularExpression(
    pattern: #"\b[A-Za-z0-9_-]{24,}\b"#
  )

  private static func replacing(_ expression: NSRegularExpression, in text: String) -> String {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: "<redacted>"
    )
  }
}

/// Logger facade. Every message is redacted before it reaches the unified log, so a call site
/// cannot leak a credential by accident.
public struct AppLog: Sendable {
  public static let subsystem = "ai.opencode.migration"

  private let logger: Logger

  public init(category: AppLogCategory) {
    logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
  }

  public func debug(_ message: @autoclosure () -> String) {
    let redacted = LogRedactor.redact(message())
    logger.debug("\(redacted, privacy: .public)")
  }

  public func info(_ message: @autoclosure () -> String) {
    let redacted = LogRedactor.redact(message())
    logger.info("\(redacted, privacy: .public)")
  }

  public func error(_ message: @autoclosure () -> String) {
    let redacted = LogRedactor.redact(message())
    logger.error("\(redacted, privacy: .public)")
  }
}
