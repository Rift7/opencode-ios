import Foundation

/// One answer a form field accepts. The server sends booleans, numbers and strings, and string
/// arrays for a multiselect; decoding tries those in that order, as the audited codec does.
public enum FormValue: Equatable, Sendable, Codable {
  case string(String)
  case number(Double)
  case boolean(Bool)
  case strings([String])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String].self) {
      self = .strings(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported form value")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .boolean(let value): try container.encode(value)
    case .strings(let values): try container.encode(values)
    }
  }

  /// A number typed in the app's formatting locale. Blank or unreadable text is no answer.
  public static func typedNumber(_ text: String, locale: Locale = .current) -> FormValue? {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let formatter = NumberFormatter()
    formatter.locale = locale
    if let grouping = formatter.groupingSeparator, !grouping.isEmpty {
      cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
    }
    if let decimal = formatter.decimalSeparator, decimal != ".", !decimal.isEmpty {
      cleaned = cleaned.replacingOccurrences(of: decimal, with: ".")
    }
    guard !cleaned.isEmpty else { return nil }
    if cleaned.hasSuffix(".") { cleaned.removeLast() }
    guard !cleaned.isEmpty, let value = Double(cleaned) else { return nil }
    return .number(value)
  }
}

public struct FormOption: Equatable, Sendable, Codable {
  public var value: String
  public var label: String
  public var description: String?

  public init(value: String, label: String, description: String? = nil) {
    self.value = value
    self.label = label
    self.description = description
  }
}

public struct FormCondition: Equatable, Sendable, Codable {
  public enum Operation: String, Equatable, Sendable, Codable {
    case eq
    case neq
  }

  public var key: String
  public var op: Operation
  public var value: FormValue

  public init(key: String, op: Operation, value: FormValue) {
    self.key = key
    self.op = op
    self.value = value
  }
}

public enum FormFieldType: String, Equatable, Sendable, Codable {
  case string
  case number
  case integer
  case boolean
  case multiselect
  case external
}

/// Why a field's answer cannot be sent. Typed so the view owns the sentence.
public enum FormValidationProblem: Equatable, Sendable {
  case required
  case completeStep
  case minLength(Int)
  case maxLength(Int)
  case invalidFormat
  case chooseOption
  case invalidEmail
  case invalidURL
  case invalidDate
  case invalidDateTime
  case minimum(Double)
  case maximum(Double)
  case wholeNumber
  case minItems(Int)
  case maxItems(Int)
  case invalidValue
}

public struct FormField: Equatable, Sendable, Codable {
  public var key: String
  public var type: FormFieldType
  public var title: String?
  public var description: String?
  public var required: Bool?
  public var conditions: [FormCondition]?
  public var format: String?
  public var minLength: Int?
  public var maxLength: Int?
  public var pattern: String?
  public var options: [FormOption]?
  public var custom: Bool?
  public var minimum: Double?
  public var maximum: Double?
  public var minItems: Int?
  public var maxItems: Int?
  public var url: String?
  public var defaultValue: FormValue?

  enum CodingKeys: String, CodingKey {
    case key, type, title, description, required, format, minLength, maxLength, pattern, options,
      custom, minimum, maximum, minItems, maxItems, url
    case conditions = "when"
    case defaultValue = "default"
  }

  public init(
    key: String,
    type: FormFieldType,
    title: String? = nil,
    description: String? = nil,
    required: Bool? = nil,
    conditions: [FormCondition]? = nil,
    format: String? = nil,
    minLength: Int? = nil,
    maxLength: Int? = nil,
    pattern: String? = nil,
    options: [FormOption]? = nil,
    custom: Bool? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    minItems: Int? = nil,
    maxItems: Int? = nil,
    url: String? = nil,
    defaultValue: FormValue? = nil
  ) {
    self.key = key
    self.type = type
    self.title = title
    self.description = description
    self.required = required
    self.conditions = conditions
    self.format = format
    self.minLength = minLength
    self.maxLength = maxLength
    self.pattern = pattern
    self.options = options
    self.custom = custom
    self.minimum = minimum
    self.maximum = maximum
    self.minItems = minItems
    self.maxItems = maxItems
    self.url = url
    self.defaultValue = defaultValue
  }

  /// Every condition must hold. A condition on an unanswered field is false, so a dependent field
  /// stays hidden until its parent has a value.
  public func isVisible(answers: [String: FormValue]) -> Bool {
    (conditions ?? []).allSatisfy { condition in
      guard let answer = answers[condition.key] else { return false }
      let matches: Bool
      if case .strings(let values) = answer, case .string(let expected) = condition.value {
        matches = values.contains(expected)
      } else {
        matches = answer == condition.value
      }
      return condition.op == .neq ? !matches : matches
    }
  }

  public func validationProblem(_ value: FormValue?) -> FormValidationProblem? {
    if type == .external && value != .boolean(true) { return .completeStep }
    if required == true && value == nil { return .required }
    guard let value else { return nil }

    switch (type, value) {
    case (.string, .string(let text)):
      let length = text.unicodeScalars.count
      if required == true && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .required
      }
      if let minLength, length < minLength { return .minLength(minLength) }
      if let maxLength, length > maxLength { return .maxLength(maxLength) }
      if let pattern {
        let matches = (try? NSRegularExpression(pattern: pattern))?
          .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        if !matches { return .invalidFormat }
      }
      if let options, custom != true, !options.contains(where: { $0.value == text }) {
        return .chooseOption
      }
      if format == "email" && !text.contains("@") { return .invalidEmail }
      if format == "uri", URL(string: text)?.scheme == nil { return .invalidURL }
      if format == "date", !Self.isoDate(text) { return .invalidDate }
      if format == "date-time", ISO8601DateFormatter().date(from: text) == nil {
        return .invalidDateTime
      }
    case (.number, .number(let number)), (.integer, .number(let number)):
      if let minimum, number < minimum { return .minimum(minimum) }
      if let maximum, number > maximum { return .maximum(maximum) }
      if type == .integer && number.rounded() != number { return .wholeNumber }
    case (.multiselect, .strings(let values)):
      if required == true && values.isEmpty { return .required }
      if let minItems, values.count < minItems { return .minItems(minItems) }
      if let maxItems, values.count > maxItems { return .maxItems(maxItems) }
    case (.boolean, .boolean), (.external, .boolean):
      break
    default:
      return .invalidValue
    }
    return nil
  }

  private static func isoDate(_ text: String) -> Bool {
    guard text.count == 10 else { return false }
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
  }
}

public struct FormRequest: Equatable, Sendable, Codable, Identifiable {
  public var id: String
  public var sessionID: String
  public var title: String
  public var fields: [FormField]
  public var metadata: [String: JSONValue]?

  public init(
    id: String,
    sessionID: String,
    title: String,
    fields: [FormField],
    metadata: [String: JSONValue]? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.title = title
    self.fields = fields
    self.metadata = metadata
  }

  public var isQuestion: Bool { metadata?["kind"]?.stringValue == "question" }
  public var isGlobal: Bool { sessionID == "global" }
  public var mcpServer: String? {
    let value = metadata?["server"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (value?.isEmpty ?? true) ? nil : value
  }

  public var defaultAnswers: [String: FormValue] {
    var answers: [String: FormValue] = [:]
    for field in fields {
      if let value = field.defaultValue {
        answers[field.key] = value
      } else if field.type == .external {
        answers[field.key] = .boolean(false)
      }
    }
    return answers
  }

  /// Fields visible under the answers, with hidden fields' answers dropped as the walk proceeds.
  public func activeFields(answers: [String: FormValue]) -> [FormField] {
    var active: [FormField] = []
    var activeAnswers = answers
    for field in fields {
      if field.isVisible(answers: activeAnswers) {
        active.append(field)
      } else {
        activeAnswers[field.key] = nil
      }
    }
    return active
  }

  public struct ValidationFailure: Error, Equatable, Sendable {
    public var problem: FormValidationProblem
    public var fieldKey: String
    public var fieldIndex: Int

    public init(problem: FormValidationProblem, fieldKey: String, fieldIndex: Int) {
      self.problem = problem
      self.fieldKey = fieldKey
      self.fieldIndex = fieldIndex
    }
  }

  /// Only visible answers are sent. Validation stops at the first failing active field.
  public func validatedAnswer(
    answers: [String: FormValue]
  ) -> Result<[String: FormValue], ValidationFailure> {
    let active = activeFields(answers: answers)
    for (index, field) in active.enumerated() {
      if let problem = field.validationProblem(answers[field.key]) {
        return .failure(ValidationFailure(problem: problem, fieldKey: field.key, fieldIndex: index))
      }
    }
    var result: [String: FormValue] = [:]
    for field in active {
      if let value = answers[field.key] { result[field.key] = value }
    }
    return .success(result)
  }
}

public enum PermissionDecision: String, Equatable, Sendable, Codable {
  case once
  case always
  case reject
}

public struct PermissionRequest: Equatable, Sendable, Codable, Identifiable {
  public struct Source: Equatable, Sendable, Codable {
    public var messageID: String
    public var id: String

    public init(messageID: String, id: String) {
      self.messageID = messageID
      self.id = id
    }
  }

  public var id: String
  public var sessionID: String
  public var action: String
  public var resources: [String]
  public var save: [String]?
  public var metadata: [String: JSONValue]?
  public var source: Source?

  public init(
    id: String,
    sessionID: String,
    action: String,
    resources: [String],
    save: [String]? = nil,
    metadata: [String: JSONValue]? = nil,
    source: Source? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.action = action
    self.resources = resources
    self.save = save
    self.metadata = metadata
    self.source = source
  }

  /// The edit preview (`metadata.files[0].patch`) and its file, when a tool asked to edit one.
  public var filePreview: (file: String, patch: String)? {
    guard let files = metadata?["files"], case .array(let entries) = files,
      let first = entries.first?.objectValue,
      let patch = first["patch"]?.stringValue,
      !patch.isEmpty
    else { return nil }
    let file = first["file"]?.stringValue ?? resources.first ?? ""
    return (file, patch)
  }
}

public struct PendingRequests: Equatable, Sendable {
  public var permissions: [PermissionRequest]
  public var forms: [FormRequest]

  public init(permissions: [PermissionRequest] = [], forms: [FormRequest] = []) {
    self.permissions = permissions
    self.forms = forms
  }

  public var isEmpty: Bool { permissions.isEmpty && forms.isEmpty }
}

public enum FormStatus: String, Equatable, Sendable, Codable {
  case pending
  case answered
  case cancelled
}

public struct FormState: Equatable, Sendable, Codable {
  public var status: FormStatus
  public var answer: [String: FormValue]?
  public var message: String?

  public init(status: FormStatus, answer: [String: FormValue]? = nil, message: String? = nil) {
    self.status = status
    self.answer = answer
    self.message = message
  }
}

/// What a reply asked the server to settle.
public enum FormSettlement: Equatable, Sendable {
  case answered([String: FormValue])
  case cancelled(String?)

  public func matches(_ state: FormState) -> Bool {
    switch self {
    case .answered(let answer):
      return state.status == .answered && state.answer == answer
    case .cancelled(let message):
      let wanted = message?.trimmingCharacters(in: .whitespacesAndNewlines)
      let actual = state.message?.trimmingCharacters(in: .whitespacesAndNewlines)
      return state.status == .cancelled && (actual?.isEmpty ?? true ? nil : actual) == (wanted?.isEmpty ?? true ? nil : wanted)
    }
  }

  public var conflict: RequestConflict {
    switch self {
    case .answered:
      return .answeredElsewhere
    case .cancelled:
      return .dismissedElsewhere
    }
  }
}

public enum RequestConflict: Equatable, Sendable {
  case answeredElsewhere
  case dismissedElsewhere
  case noLongerWaiting
}

/// The outcome of a form reply or dismissal. A conflict is a settled request, not a transport
/// failure: the answer stays visible so the person can see what happened.
public enum FormReplyOutcome: Equatable, Sendable {
  case settled
  case conflict(RequestConflict)
}

/// An undelivered prompt in a session's inbox.
public struct PendingInput: Equatable, Sendable, Identifiable {
  public enum Delivery: String, Equatable, Sendable {
    case steer
    case queue
  }

  public var id: String
  public var text: String
  public var delivery: Delivery
  public var isCompaction: Bool

  public init(id: String, text: String, delivery: Delivery, isCompaction: Bool = false) {
    self.id = id
    self.text = text
    self.delivery = delivery
    self.isCompaction = isCompaction
  }
}
