import Foundation
import OpenCodeServer
import Testing

@Suite("Server event decoding")
struct ServerEventDecoderTests {
  private func decode(_ json: String) throws -> ServerEvent? {
    try ServerEventDecoder.decode(json)
  }

  @Test("server.connected has no session")
  func connected() throws {
    #expect(try decode(#"{"type":"server.connected"}"#) == .connected)
  }

  @Test("an unknown event type is ignored without decoding its data")
  func unknownType() throws {
    #expect(try decode(#"{"type":"future.thing","data":{"anything":[1,2,3]}}"#) == nil)
  }

  @Test("malformed JSON and a wrong field type are ignored")
  func malformed() throws {
    #expect(try decode("not json") == nil)
    #expect(try decode(#"{"type":42}"#) == nil)
    #expect(try decode(#"{"type":"session.renamed","data":{"sessionID":1,"title":"x"}}"#) == nil)
  }

  @Test("a server failure frame throws instead of being skipped")
  func serverFailure() {
    #expect(throws: ServerEventError.serverFailure) {
      _ = try decode(#"{"_tag":"UnknownError","data":{"message":"boom"}}"#)
    }
  }

  @Test("a text delta carries session, message, ordinal and text")
  func textDelta() throws {
    #expect(
      try decode(
        #"{"type":"session.text.delta","data":{"sessionID":"s1","assistantMessageID":"m1","ordinal":2,"delta":"hi"}}"#
      ) == .contentBatch(
        sessionID: "s1",
        events: [.textDelta(messageID: "m1", ordinal: 2, delta: "hi", accumulatedText: nil)]
      )
    )
  }

  @Test("a text end and a tool success carry their authoritative content")
  func textEndAndToolSuccess() throws {
    #expect(
      try decode(
        #"{"type":"session.text.ended","data":{"sessionID":"s1","assistantMessageID":"m1","ordinal":0,"text":"done"}}"#
      ) == .contentBatch(sessionID: "s1", events: [.textEnded(messageID: "m1", ordinal: 0, text: "done")])
    )
    #expect(
      try decode(
        #"{"type":"session.tool.success","data":{"sessionID":"s1","assistantMessageID":"m1","id":"t1","content":[{"type":"text","text":"ok"},{"type":"file","text":"skip"}],"metadata":{"exit":0}}}"#
      ) == .contentBatch(
        sessionID: "s1",
        events: [
          .toolSucceeded(
            messageID: "m1",
            toolID: "t1",
            output: ["ok"],
            metadata: ["exit": .number(0)]
          )
        ]
      )
    )
  }

  @Test("a tool failure without a message reads as the shared copy")
  func toolFailureDefaultCopy() throws {
    #expect(
      try decode(
        #"{"type":"session.tool.failed","data":{"sessionID":"s1","assistantMessageID":"m1","id":"t1"}}"#
      ) == .contentBatch(
        sessionID: "s1",
        events: [
          .toolFailed(
            messageID: "m1", toolID: "t1", error: "Tool failed", errorType: nil, output: [],
            metadata: [:]
          )
        ]
      )
    )
  }

  @Test("a superseded interrupt is not an execution end")
  func supersededInterrupt() throws {
    #expect(
      try decode(
        #"{"type":"session.execution.interrupted","data":{"sessionID":"s1","reason":"superseded"}}"#
      ) == nil
    )
    #expect(
      try decode(#"{"type":"session.execution.interrupted","data":{"sessionID":"s1","reason":"user"}}"#)
        == .executionEnded(sessionID: "s1")
    )
  }

  @Test("a fork is a new root even though it names its source")
  func forkedSession() throws {
    #expect(
      try decode(#"{"type":"session.forked","data":{"sessionID":"new","parentID":"old"}}"#)
        == .sessionCreated(sessionID: "new", parentID: nil)
    )
    #expect(
      try decode(#"{"type":"session.created","data":{"sessionID":"child","parentID":"root"}}"#)
        == .sessionCreated(sessionID: "child", parentID: "root")
    )
  }

  @Test("a viewed watermark is milliseconds, and archives flip a flag")
  func viewedAndArchived() throws {
    #expect(
      try decode(#"{"type":"session.viewed","data":{"sessionID":"s1","idle":1750000000000}}"#)
        == .sessionViewChanged(sessionID: "s1", idle: 1_750_000_000_000)
    )
    #expect(
      try decode(#"{"type":"session.archived","data":{"sessionID":"s1"}}"#)
        == .sessionArchiveChanged(sessionID: "s1", isArchived: true)
    )
    #expect(
      try decode(#"{"type":"session.unarchived","data":{"sessionID":"s1"}}"#)
        == .sessionArchiveChanged(sessionID: "s1", isArchived: false)
    )
  }

  @Test("a move without a directory invalidates history instead")
  func moveWithoutDirectory() throws {
    #expect(
      try decode(#"{"type":"session.moved","data":{"sessionID":"s1"}}"#)
        == .messageInvalidated(sessionID: "s1")
    )
    #expect(
      try decode(#"{"type":"session.moved","data":{"sessionID":"s1","location":{"directory":"/w"}}}"#)
        == .sessionMoved(sessionID: "s1", directory: "/w")
    )
  }

  @Test("a global form raises no attention")
  func globalForm() throws {
    #expect(
      try decode(#"{"type":"form.created","data":{"form":{"sessionID":"global"}}}"#) == nil
    )
    #expect(
      try decode(#"{"type":"permission.asked","data":{"sessionID":"s1"}}"#)
        == .attentionChanged(askedSessionID: "s1")
    )
    #expect(
      try decode(#"{"type":"permission.replied","data":{"sessionID":"s1"}}"#)
        == .attentionChanged(askedSessionID: nil)
    )
  }

  @Test("inbox events carry the admitted identity")
  func inboxEvents() throws {
    #expect(
      try decode(#"{"type":"session.inbox.enqueued","data":{"sessionID":"s1","inboxID":"i1"}}"#)
        == .inputEnqueued(sessionID: "s1", inputID: "i1")
    )
    #expect(
      try decode(#"{"type":"session.inbox.cancelled","data":{"sessionID":"s1","inboxID":"i1"}}"#)
        == .inputCancelled(sessionID: "s1", inputID: "i1")
    )
    #expect(
      try decode(#"{"type":"session.inbox.delivered","data":{"sessionID":"s1","inboxID":"i1"}}"#)
        == .inputQueueChanged(sessionID: "s1", inputID: "i1")
    )
  }

  @Test("revert events carry a boundary, a redo, or a commit")
  func revertEvents() throws {
    #expect(
      try decode(#"{"type":"session.revert.staged","data":{"sessionID":"s1","revert":{"messageID":"m1"}}}"#)
        == .revertChanged(sessionID: "s1", messageID: "m1", committed: false)
    )
    #expect(
      try decode(#"{"type":"session.revert.committed","data":{"sessionID":"s1"}}"#)
        == .revertChanged(sessionID: "s1", messageID: nil, committed: true)
    )
  }

  @Test("a running shell starts, an exited one ends, and an unknown status is finished")
  func shellEvents() throws {
    let started = try decode(
      #"{"type":"shell.created","data":{"info":{"id":"sh1","status":"running","command":"npm test","metadata":{"sessionID":"s1","background":true},"time":{"started":1750000000000}}}}"#
    )
    guard case .shellStarted(let shell) = try #require(started) else {
      Issue.record("expected a started shell")
      return
    }
    #expect(shell.id == "sh1")
    #expect(shell.sessionID == "s1")
    #expect(shell.isUserCommand)
    #expect(shell.status == .running)
    #expect(shell.title == "npm test")

    #expect(try decode(#"{"type":"shell.exited","data":{"id":"sh1"}}"#) == .shellEnded(shellID: "sh1"))

    #expect(try decode(#"{"type":"shell.created","data":{"info":{"id":"sh2","status":"exited","command":"x"}}}"#) == nil)
  }

  @Test("a job update decodes its own info shape")
  func jobUpdated() throws {
    let event = try decode(
      #"{"type":"experimental.job.updated","data":{"info":{"id":"j1","kind":"subagent","sessionID":"s1","status":"running","childSessionID":"s2","time":{"started":1750000000000}}}}"#
    )
    guard case .jobUpdated(let job) = try #require(event) else {
      Issue.record("expected a job update")
      return
    }
    #expect(job.id == "j1")
    #expect(job.kind == .subagent)
    #expect(job.isRunning)
    #expect(job.ownerSessionID == "s2")
  }

  @Test("a project update carries the resolved name")
  func projectUpdated() throws {
    let event = try decode(
      #"{"type":"project.updated","data":{"id":"p1","canonical":"/Users/me/box","repository":"github.com/acme/box"}}"#
    )
    guard case .projectUpdated(let project) = try #require(event) else {
      Issue.record("expected a project update")
      return
    }
    #expect(project.id == "p1")
    #expect(project.name == "box")
    #expect(project.repository == "box")
  }

  @Test("model, provider and agent updates are distinct")
  func catalogUpdates() throws {
    #expect(try decode(#"{"type":"model.updated"}"#) == .modelsChanged)
    #expect(try decode(#"{"type":"provider.updated"}"#) == .modelsChanged)
    #expect(try decode(#"{"type":"agent.updated"}"#) == .agentsChanged)
  }
}

@Suite("Content event coalescing")
struct LiveContentEventTests {
  @Test("adjacent deltas for one part merge, and nothing else does")
  func coalescing() {
    var events: [LiveContentEvent] = [
      .textDelta(messageID: "m", ordinal: 1, delta: "a", accumulatedText: nil),
      .textDelta(messageID: "m", ordinal: 1, delta: "b", accumulatedText: nil),
      .textDelta(messageID: "m", ordinal: 2, delta: "c", accumulatedText: nil),
      .toolInputDelta(messageID: "m", toolID: "t", delta: "x"),
      .toolInputDelta(messageID: "m", toolID: "t", delta: "y"),
    ]
    var coalesced: [LiveContentEvent] = []
    coalesced.appendCoalescingDeltas(events)
    #expect(
      coalesced == [
        .textDelta(messageID: "m", ordinal: 1, delta: "ab", accumulatedText: nil),
        .textDelta(messageID: "m", ordinal: 2, delta: "c", accumulatedText: nil),
        .toolInputDelta(messageID: "m", toolID: "t", delta: "xy"),
      ]
    )
    events.removeAll()
  }

  @Test("a delta with a server-observed prefix never merges")
  func accumulatedPrefixStopsMerging() {
    let first = LiveContentEvent.textDelta(messageID: "m", ordinal: 0, delta: "a", accumulatedText: "a")
    let second = LiveContentEvent.textDelta(messageID: "m", ordinal: 0, delta: "b", accumulatedText: "ab")
    #expect(first.appendingDelta(second) == nil)
  }

  @Test("durable boundaries and transcript identities match the REST projection")
  func boundaries() {
    #expect(LiveContentEvent.toolCalled(messageID: "m", toolID: "t", input: .object([:])).isDurableBoundary)
    #expect(!LiveContentEvent.textDelta(messageID: "m", ordinal: 0, delta: "a", accumulatedText: nil).isDurableBoundary)
    #expect(
      LiveContentEvent.textStarted(messageID: "m", ordinal: 3).transcriptItemID == "m-text-3"
    )
    #expect(
      LiveContentEvent.toolSucceeded(messageID: "m", toolID: "t", output: [], metadata: [:]).transcriptItemID
        == "m-tool-t"
    )
    #expect(LiveContentEvent.stepStarted(messageID: "m").transcriptItemID == nil)
  }
}
