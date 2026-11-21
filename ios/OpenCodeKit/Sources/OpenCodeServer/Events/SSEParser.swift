import Foundation

/// One dispatched SSE frame. The server sends one `data:` line per event and `: heartbeat`
/// comments between them, but the parser accepts the general field syntax so a change upstream
/// cannot corrupt the stream.
public struct SSEFrame: Sendable, Equatable {
  public var event: String?
  public var id: String?
  public var data: String

  public init(event: String? = nil, id: String? = nil, data: String) {
    self.event = event
    self.id = id
    self.data = data
  }
}

public enum SSEError: Error, Equatable, Sendable {
  /// A single frame (or line) passed the size bound, so the rest of the connection is unusable.
  case frameTooLarge
}

/// An incremental `text/event-stream` parser.
///
/// Bytes arrive in whatever pieces the network hands over: a frame can be split mid-line, mid-UTF-8
/// or between the `data:` field and its value. The parser buffers until a line ends, and dispatches
/// a frame only on the blank line that terminates it. A frame larger than the audited 16 MiB bound
/// fails the connection rather than growing memory.
public struct SSEParser: Sendable {
  public static let maximumFrameBytes = 16 * 1024 * 1024

  public private(set) var lineCount = 0

  private var line: [UInt8] = []
  private var pendingCarriageReturn = false
  private var dataLines: [String] = []
  private var eventName: String?
  private var eventID: String?
  private var frameBytes = 0
  private let maximumBytes: Int

  public init(maximumFrameBytes: Int = SSEParser.maximumFrameBytes) {
    self.maximumBytes = max(1, maximumFrameBytes)
  }

  /// Feeds bytes and returns every frame completed by them.
  public mutating func feed(_ data: Data) throws -> [SSEFrame] {
    var frames: [SSEFrame] = []
    for byte in data {
      if pendingCarriageReturn {
        pendingCarriageReturn = false
        if byte == 0x0A { continue }
      }
      switch byte {
      case 0x0D:
        pendingCarriageReturn = true
        try endLine(into: &frames)
      case 0x0A:
        try endLine(into: &frames)
      default:
        line.append(byte)
        if line.count + frameBytes > maximumBytes { throw SSEError.frameTooLarge }
      }
    }
    return frames
  }

  /// Flushes a final unterminated line and frame at end of input.
  public mutating func finish() throws -> [SSEFrame] {
    var frames: [SSEFrame] = []
    if !line.isEmpty {
      try endLine(into: &frames)
    }
    if let frame = dispatch() {
      frames.append(frame)
    }
    return frames
  }

  private mutating func endLine(into frames: inout [SSEFrame]) throws {
    lineCount += 1
    let text = String(decoding: line, as: UTF8.self)
    line.removeAll(keepingCapacity: true)
    if text.isEmpty {
      if let frame = dispatch() {
        frames.append(frame)
      }
      return
    }
    parseField(text)
  }

  private mutating func parseField(_ text: String) {
    if text.hasPrefix(":") { return }
    let field: String
    var value: String
    if let colon = text.firstIndex(of: ":") {
      field = String(text[..<colon])
      value = String(text[text.index(after: colon)...])
      if value.hasPrefix(" ") { value.removeFirst() }
    } else {
      field = text
      value = ""
    }
    switch field {
    case "data":
      dataLines.append(value)
      frameBytes += value.utf8.count
    case "event":
      eventName = value
    case "id":
      eventID = value
    default:
      break
    }
  }

  private mutating func dispatch() -> SSEFrame? {
    defer {
      dataLines.removeAll(keepingCapacity: true)
      eventName = nil
      eventID = nil
      frameBytes = 0
    }
    guard !dataLines.isEmpty else { return nil }
    return SSEFrame(event: eventName, id: eventID, data: dataLines.joined(separator: "\n"))
  }
}
