import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Session model and agent selection", .serialized)
struct SessionSelectionTests {
  private let server = OpenCodeServer(url: "http://127.0.0.1:4110", password: "token")
  private let root = OpenCodeSession(
    id: "root",
    serverTitle: "Root",
    projectID: "p1",
    directory: "/work/opencode",
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )

  private final class Calls: Sendable {
    private let values = Mutex<[String]>([])
    func append(_ value: String) { values.withLock { $0.append(value) } }
    var all: [String] { values.withLock { $0 } }
  }

  private func state(newSession: Bool = false) -> SessionFeature.State {
    let selection = SessionSelection(
      serverID: server.persistenceID,
      sessionID: newSession ? "new-id" : "root",
      intent: newSession ? .newSession(directory: "/work/opencode") : .browse
    )
    return SessionFeature.State(
      id: 1,
      server: server,
      selection: selection,
      session: newSession ? nil : root
    )
  }

  private func client(_ calls: Calls) -> OpenCodeClient {
    var client = OpenCodeClient.testValue
    client.switchAgent = { _, _, agent in calls.append("agent:\(agent)") }
    client.switchModel = { _, _, model in calls.append("model:\(model.providerID)/\(model.id)/\(model.variant ?? "-")") }
    client.sendPrompt = { _, _, body in
      calls.append("prompt:\(body.agents?.first?.name ?? "none"):\(body.skills?.first?.id ?? "none")")
    }
    return client
  }

  private func store(_ client: OpenCodeClient) -> TestStoreOf<SessionFeature> {
    let store = TestStore(initialState: state()) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = client
      $0.clock = .testValue
      $0.networkPath = NetworkPathClient(current: { .online }, updates: { AsyncStream { $0.finish() } }, waitUntilAvailable: {})
      $0.haptics = .testValue
      $0.composerDrafts = .live(store: ComposerDraftStore(storage: InMemoryStorage(), storageKey: "drafts"))
    }
    store.exhaustivity = .off
    return store
  }

  @Test("a send applies agent then model and posts the mentions exactly once")
  func sendAppliesSelectionBeforePrompt() async {
    let calls = Calls()
    let store = store(client(calls))
    let skill = ComposerMentionChip(
      id: "skill:review",
      kind: .skill,
      value: "review",
      token: "@review",
      title: "review",
      start: 4,
      end: 11
    )
    let agent = ComposerMentionChip(
      id: "agent:build",
      kind: .agent,
      value: "build",
      token: "@build",
      title: "build",
      start: 17,
      end: 23
    )
    let send = ComposerSend(
      target: .session(id: "root"),
      messageID: "m-selection",
      text: "Use @review with @build",
      quotes: [],
      delivery: .steer,
      revision: 1,
      chips: [skill, agent],
      model: ModelRef(id: "opus", providerID: "anthropic", variant: "high"),
      agent: "build"
    )
    await store.send(.composer(.delegate(.send(send))))
    for _ in 0..<20 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
      if calls.all.count >= 3 { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(calls.all == ["agent:build", "model:anthropic/opus/high", "prompt:build:review"])
  }

  @Test("a session already on the chosen model and agent posts no redundant switches")
  func unchangedSelectionIsNotReapplied() async {
    let calls = Calls()
    let model = ModelRef(id: "opus", providerID: "anthropic", variant: "high")
    let session = OpenCodeSession(
      id: "root",
      serverTitle: "Root",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      model: model,
      agent: "build"
    )
    let initial = SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(serverID: server.persistenceID, sessionID: "root", intent: .browse),
      session: session
    )
    var configured = initial
    configured.composer.selectedModel = model
    configured.composer.selectedAgent = "build"
    let store = TestStore(initialState: configured) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = client(calls)
      $0.clock = .testValue
      $0.networkPath = NetworkPathClient(current: { .online }, updates: { AsyncStream { $0.finish() } }, waitUntilAvailable: {})
      $0.haptics = .testValue
      $0.composerDrafts = .live(store: ComposerDraftStore(storage: InMemoryStorage(), storageKey: "drafts"))
    }
    store.exhaustivity = .off
    let send = ComposerSend(
      target: .session(id: "root"),
      messageID: "m-unchanged",
      text: "hello",
      quotes: [],
      delivery: .steer,
      revision: 1,
      model: model,
      agent: "build"
    )
    await store.send(.composer(.delegate(.send(send))))
    for _ in 0..<20 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
      if !calls.all.isEmpty { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(calls.all == ["prompt:none:none"])
  }

  @Test("cancellation after an agent switch prevents the model and prompt")
  func cancellationAfterAgentPreventsLaterMutations() async {
    let calls = Calls()
    let gate = AgentGate()
    var client = OpenCodeClient.testValue
    client.switchAgent = { _, _, agent in
      calls.append("agent:\(agent)")
      await gate.wait()
    }
    client.switchModel = { _, _, model in
      calls.append("model:\(model.id)")
    }
    client.sendPrompt = { _, _, body in
      calls.append("prompt:\(body.text)")
    }
    let store = store(client)
    let send = ComposerSend(
      target: .session(id: "root"),
      messageID: "m-cancel",
      text: "hello",
      quotes: [],
      delivery: .steer,
      revision: 1,
      model: ModelRef(id: "opus", providerID: "anthropic"),
      agent: "build"
    )
    await store.send(.composer(.delegate(.send(send))))
    #expect(await gate.waitUntilStarted())
    await store.send(.connectionChanged(isConnected: false))
    await gate.release()
    for _ in 0..<20 {
      await store.skipReceivedActions(strict: false)
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(calls.all == ["agent:build"])
  }

  @Test("a refused switch fails the send without posting it")
  func refusedSwitchDoesNotPost() async {
    let calls = Calls()
    var client = OpenCodeClient.testValue
    client.switchAgent = { _, _, _ in throw OpenCodeClientError(.status(409)) }
    client.sendPrompt = { _, _, _ in calls.append("prompt") }
    let store = store(client)
    let send = ComposerSend(
      target: .session(id: "root"),
      messageID: "m-refused",
      text: "hello",
      quotes: [],
      delivery: .steer,
      revision: 1,
      model: nil,
      agent: "build"
    )
    await store.send(.composer(.delegate(.send(send))))
    for _ in 0..<20 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(calls.all.isEmpty)
    #expect(!store.state.composer.isSending)
  }
}


private actor AgentGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilStarted() async -> Bool {
    for _ in 0..<100 {
      if started { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return started
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
