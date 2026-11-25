import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Composer catalogue ownership", .serialized)
struct ComposerCatalogTests {
  private let server = OpenCodeServer(url: "http://127.0.0.1:4110", password: "token")

  private actor Gate {
    private var modelWaiters: [CheckedContinuation<Void, Never>] = []
    private var autocompleteWaiters: [CheckedContinuation<Void, Never>] = []
    private var agentWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var modelStarted = 0
    private(set) var autocompleteStarted = 0
    private(set) var agentStarted = 0

    func waitModel() async {
      modelStarted += 1
      await withCheckedContinuation { modelWaiters.append($0) }
    }

    func waitAutocomplete() async {
      autocompleteStarted += 1
      await withCheckedContinuation { autocompleteWaiters.append($0) }
    }

    func waitAgent() async {
      agentStarted += 1
      await withCheckedContinuation { agentWaiters.append($0) }
    }

    func release() {
      for waiter in modelWaiters { waiter.resume() }
      for waiter in autocompleteWaiters { waiter.resume() }
      for waiter in agentWaiters { waiter.resume() }
      modelWaiters = []
      autocompleteWaiters = []
      agentWaiters = []
    }

    var started: (model: Int, autocomplete: Int, agent: Int) {
      (modelStarted, autocompleteStarted, agentStarted)
    }
  }

  private func client(_ gate: Gate) -> OpenCodeClient {
    var client = OpenCodeClient.testValue
    client.modelCatalog = { _, _ in
      await gate.waitModel()
      return ModelCatalog(
        models: [
          ServerModel(modelID: "model", providerID: "provider", name: "Model")
        ],
        defaultModel: ServerModel(modelID: "model", providerID: "provider", name: "Model")
      )
    }
    client.agents = { _, _, _ in
      await gate.waitAgent()
      return [ServerAgent(id: "build", name: "build", mode: "primary")]
    }
    client.skills = { _, _ in
      await gate.waitAutocomplete()
      return [ServerSkill(id: "review", name: "review")]
    }
    client.commands = { _, _ in
      [ServerCommand(name: "init")]
    }
    return client
  }

  private func makeStore(_ gate: Gate) -> TestStoreOf<ComposerFeature> {
    var state = ComposerFeature.State(
      serverID: server.persistenceID,
      target: .session(id: "session")
    )
    state.server = server
    state.uploadDirectory = "/work/opencode"
    let store = TestStore(initialState: state) {
      ComposerFeature()
    } withDependencies: {
      $0.openCodeClient = client(gate)
      $0.composerDrafts = .testValue
      $0.clock = .testValue
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    return store
  }

  private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }

  @Test("the real load path completes model, agent and autocomplete work independently")
  func independentResultsArrive() async {
    let gate = Gate()
    let store = makeStore(gate)
    await store.send(.modelPickerOpened)
    #expect(
      await waitUntil {
        let started = await gate.started
        return started.model == 1 && started.autocomplete == 1 && started.agent == 1
      }
    )
    await gate.release()
    for _ in 0..<20 {
      await store.skipReceivedActions(strict: false)
      if store.state.catalog != nil { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.state.catalog != nil)
    #expect(store.state.autocomplete.skills.map(\.id) == ["review"])
    #expect(store.state.autocomplete.commands.map(\.name) == ["init"])
    #expect(store.state.selectedModel?.id == "model")
  }

  @Test("opening a composer loads the agent catalogue before the picker")
  func taskLoadsAgentsBeforePicker() async {
    let gate = Gate()
    let store = makeStore(gate)
    await store.send(.task)
    #expect(
      await waitUntil {
        let started = await gate.started
        return started.model == 1 && started.autocomplete == 1 && started.agent == 1
      }
    )
    await gate.release()
    for _ in 0..<20 {
      await store.skipReceivedActions(strict: false)
      if !store.state.autocomplete.agents.isEmpty { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.state.autocomplete.agents.map(\.id) == ["build"])
    #expect(store.state.selectedAgent == "build")
  }

  @Test("a repeated load cancels the first request set and only the latest results apply")
  func repeatedLoadIsFenced() async {
    let gate = Gate()
    let store = makeStore(gate)
    await store.send(.modelPickerOpened)
    #expect(await waitUntil { await gate.started.model == 1 })
    await store.send(.modelPickerOpened)
    #expect(
      await waitUntil {
        let started = await gate.started
        return started.model == 2 && started.autocomplete == 2 && started.agent == 2
      }
    )
    await gate.release()
    for _ in 0..<20 {
      await store.skipReceivedActions(strict: false)
      if store.state.catalog != nil { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.state.catalog?.models.count == 1)
    #expect(store.state.autocomplete.skills.count == 1)
  }

  @Test("results for a directory left while loading are ignored")
  func navigationFencesLateResults() async {
    let gate = Gate()
    let store = makeStore(gate)
    await store.send(.modelPickerOpened)
    #expect(await waitUntil { await gate.started.model == 1 })
    await store.send(.uploadDirectoryChanged("/work/other"))
    await gate.release()
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.catalog == nil)
    #expect(store.state.autocomplete.skills.isEmpty)
  }
}
