import Foundation

/// A JSON value kept exactly as the server sent it. Tool inputs, metadata and event extras are
/// server-defined, so they travel as data rather than being modelled field by field.
public enum JSONValue: Sendable, Equatable, Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }
}

/// Decodes a value that may not match the app's model without failing the surrounding payload.
/// Used where one unreadable extra must not cost the whole event.
public struct Lenient<Value: Codable & Sendable>: Codable, Sendable {
  public let value: Value?

  public init(_ value: Value?) {
    self.value = value
  }

  public init(from decoder: any Decoder) throws {
    value = try? Value(from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let value {
      try container.encode(value)
    } else {
      try container.encodeNil()
    }
  }
}

/// An envelope every V2 read wraps its payload in: `{ "data": … }`.
public struct DataPayload<Value: Codable & Sendable>: Codable, Sendable {
  public let data: Value

  public init(data: Value) {
    self.data = data
  }
}

/// A page cursor: present with `next` when there is another page.
public struct CursorPayload: Codable, Sendable, Equatable {
  public var next: String?

  public init(next: String? = nil) {
    self.next = next
  }
}
