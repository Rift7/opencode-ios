import Foundation
import OpenCodeServer

/// Presentation state for the composer's request dock. The request models, answers, validation and
/// settlement stay in `SessionRequests`; this only records which question page is open, what was
/// typed in the answer bar, and whether a question is folded.
public struct RequestDockState: Equatable, Sendable {
  public var answerDrafts: [String: String]
  public var questionPages: [String: Int]
  public var collapsedIDs: Set<String>
  public var showsSheet: Bool

  public init(
    answerDrafts: [String: String] = [:],
    questionPages: [String: Int] = [:],
    collapsedIDs: Set<String> = [],
    showsSheet: Bool = false
  ) {
    self.answerDrafts = answerDrafts
    self.questionPages = questionPages
    self.collapsedIDs = collapsedIDs
    self.showsSheet = showsSheet
  }

  public func isCollapsed(_ id: String) -> Bool { collapsedIDs.contains(id) }

  public func page(for formID: String) -> Int { questionPages[formID] ?? 0 }

  /// The form's active fields, and the one field the answer bar is on.
  public func field(
    for form: FormRequest,
    answers: [String: FormValue]
  ) -> (field: FormField, page: Int, count: Int)? {
    let fields = form.activeFields(answers: answers)
    guard !fields.isEmpty else { return nil }
    let count = form.isQuestion ? fields.count : 1
    let page = min(max(page(for: form.id), 0), max(count - 1, 0))
    return (fields[page], page, count)
  }

  public func target(for request: SessionRequests) -> String? {
    guard let id = request.selectedRequestID else { return nil }
    if request.permission(id) != nil { return id }
    guard let form = request.form(id), form.fitsDock,
      let selected = field(for: form, answers: request.answers[form.id] ?? form.defaultAnswers)
    else { return nil }
    return "\(form.id)/\(selected.field.key)"
  }

  public func answerText(for request: SessionRequests) -> String {
    guard let target = target(for: request) else { return "" }
    if let draft = answerDrafts[target] { return draft }
    guard let id = request.selectedRequestID, let form = request.form(id),
      let selected = field(for: form, answers: request.answers[form.id] ?? form.defaultAnswers)
    else { return "" }
    let value = request.answers[form.id]?[selected.field.key]
    if case .number(let number) = value { return formattedNumber(number) }
    return customText(value, options: selected.field.options ?? [])
  }

  /// The bar's text became the current field's answer, when the field accepts typed input.
  public mutating func answerChanged(
    _ text: String,
    request: SessionRequests,
    answers: inout [String: [String: FormValue]]
  ) {
    guard let target = target(for: request) else { return }
    answerDrafts[target] = text
    guard let id = request.selectedRequestID, let form = request.form(id),
      let selected = field(for: form, answers: answers[form.id] ?? form.defaultAnswers)
    else { return }
    guard selected.field.options?.isEmpty ?? true || selected.field.custom == true else { return }
    var values = answers[form.id] ?? [:]
    if let value = typedValue(
      text,
      field: selected.field,
      current: values[selected.field.key]
    ) {
      values[selected.field.key] = value
    } else {
      values[selected.field.key] = nil
    }
    answers[form.id] = values
  }

  public mutating func movePage(_ delta: Int, form: FormRequest, answers: [String: FormValue]) -> Bool {
    guard let selected = field(for: form, answers: answers) else { return false }
    let next = min(max(selected.page + delta, 0), max(selected.count - 1, 0))
    guard next != selected.page else { return false }
    questionPages[form.id] = next
    return true
  }

  public mutating func clearAnswers() {
    answerDrafts.removeAll()
    questionPages.removeAll()
    collapsedIDs.removeAll()
  }

  private func customText(_ value: FormValue?, options: [FormOption]) -> String {
    let known = Set(options.map(\.value))
    return switch value {
    case .string(let text): known.contains(text) ? "" : text
    case .strings(let values): values.filter { !known.contains($0) }.joined(separator: ", ")
    default: ""
    }
  }

  private func typedValue(
    _ text: String,
    field: FormField,
    current: FormValue?
  ) -> FormValue? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.type {
    case .number, .integer:
      return trimmed.isEmpty ? nil : .typedNumber(text)
    case .multiselect:
      let known = Set((field.options ?? []).map(\.value))
      var values: [String]
      if case .strings(let existing) = current {
        values = existing.filter { known.contains($0) }
      } else {
        values = []
      }
      if !trimmed.isEmpty { values.append(trimmed) }
      return values.isEmpty ? nil : .strings(values)
    default:
      return trimmed.isEmpty ? nil : .string(text)
    }
  }

  private func formattedNumber(_ value: Double) -> String {
    if value.rounded() == value { return String(Int(value)) }
    return String(value)
  }
}

extension FormRequest {
  /// A question, or one simple field, can be answered in the composer. Anything else keeps the
  /// sheet so a long form is never squeezed into the bar.
  public var fitsDock: Bool {
    if isQuestion { return true }
    return fields.count == 1 && fields[0].type != .external
  }
}
