import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Request review models")
struct RequestModelsTests {
  private func decodeForm(_ json: String) throws -> FormRequest {
    try JSONDecoder().decode(FormRequest.self, from: Data(json.utf8))
  }

  @Test("form values decode in the audited order and keep their type")
  func valueDecoding() throws {
    struct Payload: Codable { var values: [FormValue] }
    let payload = try JSONDecoder().decode(
      Payload.self,
      from: Data(#"{"values":[true,42,"text",["a","b"]]}"#.utf8)
    )
    #expect(
      payload.values == [
        .boolean(true), .number(42), .string("text"), .strings(["a", "b"]),
      ]
    )
  }

  @Test("a form's default key becomes a default answer and external steps start false")
  func defaultsAndVisibility() throws {
    let form = try decodeForm(
      """
      {"id":"f","sessionID":"s","title":"Deploy","fields":[
        {"key":"environment","type":"string","required":true,
         "options":[{"value":"staging","label":"Staging"}],"default":"staging"},
        {"key":"step","type":"external"},
        {"key":"detail","type":"string","when":[{"key":"environment","op":"eq","value":"production"}]}
      ]}
      """
    )

    #expect(form.defaultAnswers["environment"] == .string("staging"))
    #expect(form.defaultAnswers["step"] == .boolean(false))
    #expect(form.activeFields(answers: form.defaultAnswers).map(\.key) == ["environment", "step"])
    #expect(
      form.activeFields(answers: ["environment": .string("production"), "step": .boolean(true)])
        .map(\.key) == ["environment", "step", "detail"]
    )
  }

  @Test("validation reports a typed problem at the first failing active field")
  func validation() throws {
    let form = try decodeForm(
      """
      {"id":"f","sessionID":"s","title":"Deploy","fields":[
        {"key":"name","type":"string","required":true,"minLength":2},
        {"key":"count","type":"integer","minimum":1,"maximum":5},
        {"key":"kind","type":"string","options":[{"value":"a","label":"A"}]}
      ]}
      """
    )

    #expect(
      form.validatedAnswer(answers: [:])
        == .failure(.init(problem: .required, fieldKey: "name", fieldIndex: 0))
    )
    #expect(
      form.validatedAnswer(answers: ["name": .string("A")])
        == .failure(.init(problem: .minLength(2), fieldKey: "name", fieldIndex: 0))
    )
    #expect(
      form.validatedAnswer(answers: ["name": .string("Ada"), "count": .number(2.5)])
        == .failure(.init(problem: .wholeNumber, fieldKey: "count", fieldIndex: 1))
    )
    #expect(
      form.validatedAnswer(answers: ["name": .string("Ada"), "count": .number(2), "kind": .string("b")])
        == .failure(.init(problem: .chooseOption, fieldKey: "kind", fieldIndex: 2))
    )
    #expect(
      form.validatedAnswer(
        answers: ["name": .string("Ada"), "count": .number(2)]
      ) == .success(["name": .string("Ada"), "count": .number(2)])
    )
  }

  @Test("hidden answers are not sent")
  func hiddenAnswers() throws {
    let form = try decodeForm(
      """
      {"id":"f","sessionID":"s","title":"Q","fields":[
        {"key":"a","type":"boolean","default":false},
        {"key":"b","type":"string","when":[{"key":"a","op":"eq","value":true}]}
      ]}
      """
    )
    let answer = try form.validatedAnswer(
      answers: ["a": .boolean(false), "b": .string("hidden")]
    ).get()
    #expect(answer == ["a": .boolean(false)])
  }

  @Test("an unknown field type rejects the form rather than guessing")
  func strictDecoding() {
    #expect(throws: (any Error).self) {
      try decodeForm(
        """
        {"id":"f","sessionID":"s","title":"Q","fields":[{"key":"a","type":"colour"}]}
        """
      )
    }
  }

  @Test("a global question names its server and stays out of a session's family filter")
  func globalQuestion() throws {
    let form = try decodeForm(
      """
      {"id":"f","sessionID":"global","title":"Pick","metadata":{"kind":"question","server":"mcp"},
       "fields":[{"key":"a","type":"string"}]}
      """
    )
    #expect(form.isGlobal)
    #expect(form.isQuestion)
    #expect(form.mcpServer == "mcp")
  }
}
