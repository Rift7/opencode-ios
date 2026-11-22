import ComposableArchitecture
import Foundation
import OpenCodeApp
import OpenCodeCore
import OpenCodeServer
import Testing

@MainActor
@Suite("Connection feature")
struct ConnectionFeatureTests {
  private func probe() -> ServerLinkProbe {
    ServerLinkProbe(
      server: TestServer.server,
      info: TestServer.info,
      candidates: 1,
      elapsedMilliseconds: 0
    )
  }

  private func store(
    script: ScriptedClient,
    state: ConnectionFeature.State
  ) -> TestStoreOf<ConnectionFeature> {
    TestStore(initialState: state) {
      ConnectionFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.clock = ClockClient.testValue
    }
  }

  @Test("a health answer loads projects before the connection is called connected")
  func connectsAndLoadsProjects() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))

    await store.send(.task)
    await store.receive(.healthFinished(generation: 1_001, result: .success(probe()))) {
      $0.phase = .loading
      $0.info = TestServer.info
    }
    await store.receive(.delegate(.verified(TestServer.server, TestServer.info)))
    await store.receive(.streamPhase(.connected))
    await store.receive(.refreshFinished(generation: 1_001, result: .success(TestServer.projects))) {
      $0.phase = .connected
      $0.projects = TestServer.projects
    }
    await store.receive(.delegate(.projects(TestServer.server, TestServer.projects, TestServer.info)))

    #expect(script.healthCalls.count == 1)
    #expect(script.projectCalls.count == 1)

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }
  }

  @Test("a rejected password fails the connection and does not open a stream")
  func rejectedCredentials() async {
    let failure = OpenCodeClientError(.status(401))
    let script = ScriptedClient(
      health: Script([.failure(failure)]),
      projects: Script([.success([])])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))

    await store.send(.task)
    await store.receive(.healthFinished(generation: 1_001, result: .failure(failure))) {
      $0.phase = .failed
      $0.failure = .credentialsRejected
    }
    await store.receive(.delegate(.failed(.credentialsRejected)))
    #expect(script.projectCalls.count == 0)
  }

  @Test("an HTML page is incompatible API, not a decode or auth failure")
  func incompatibleAPI() async {
    let failure = OpenCodeClientError(.incompatibleAPI(feature: "server info"))
    let script = ScriptedClient(
      health: Script([.failure(failure)]),
      projects: Script([.success([])])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))

    await store.send(.task)
    await store.receive(.healthFinished(generation: 1_001, result: .failure(failure))) {
      $0.phase = .failed
      $0.failure = .incompatibleAPI(feature: "server info")
    }
    await store.receive(.delegate(.failed(.incompatibleAPI(feature: "server info"))))
  }

  @Test("a malformed payload is distinct from an incompatible API")
  func malformedPayload() async {
    let failure = OpenCodeClientError(.undecodable(feature: "server info"))
    let script = ScriptedClient(
      health: Script([.failure(failure)]),
      projects: Script([.success([])])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))

    await store.send(.task)
    await store.receive(.healthFinished(generation: 1_001, result: .failure(failure))) {
      $0.phase = .failed
      $0.failure = .malformed(feature: "server info")
    }
    await store.receive(.delegate(.failed(.malformed(feature: "server info"))))
  }

  @Test("a known-offline path fails with offline, not a credentials message")
  func offlineIsNotCredentials() async {
    let state = ConnectionFeature.State(id: 1, server: TestServer.server, isOffline: false)
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    let store = store(script: script, state: state)

    await store.send(.networkPathChanged(.offline)) {
      $0.phase = .failed
      $0.failure = .offline
      $0.isOffline = true
    }
  }

  @Test("the path returning starts the connection again")
  func pathReturnReconnects() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))
    store.exhaustivity = .off

    await store.send(.networkPathChanged(.offline)) {
      $0.phase = .failed
      $0.failure = .offline
      $0.isOffline = true
    }
    await store.send(.networkPathChanged(.online)) {
      $0.phase = .connecting
      $0.failure = nil
      $0.isOffline = false
    }
    await store.receive(.healthFinished(generation: 1_001, result: .success(probe())))
    #expect(store.state.server == TestServer.server)
    #expect(script.healthCalls.count == 1)
    await store.send(.scenePhaseChanged(isActive: false))
  }

  @Test("a stream drop shows reconnecting and the next handshake refreshes REST")
  func reconnectsAndRefreshes() async {
    let refreshed = [TestServer.projects[0]]
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects), .success(refreshed)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(.refreshFinished(generation: 1_001, result: .success(TestServer.projects)))
    #expect(store.state.phase == .connected)

    await store.send(ConnectionFeature.Action.streamPhase(.disconnected(OpenCodeClientError(.transport(.notSent))))) {
      $0.phase = .reconnecting
    }
    await store.send(ConnectionFeature.Action.streamPhase(.connected))
    await store.receive(.refreshFinished(generation: 1_001, result: .success(refreshed))) {
      $0.phase = .connected
      $0.projects = refreshed
    }

    #expect(script.projectCalls.count == 2)
  }

  @Test("an overflow resynchronizes from REST before the next handshake")
  func overflowResynchronizes() async {
    let refreshed = [TestServer.projects[1]]
    let events = ControlledEventScript()
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects), .success(refreshed)]),
      events: .controlled(events)
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))

    await store.send(.task)
    await store.receive(.healthFinished(generation: 1_001, result: .success(probe()))) {
      $0.phase = .loading
      $0.info = TestServer.info
    }
    await store.receive(.delegate(.verified(TestServer.server, TestServer.info)))

    events.push(.phase(.connected))
    await store.receive(.streamPhase(.connected))
    await store.receive(.refreshFinished(generation: 1_001, result: .success(TestServer.projects))) {
      $0.phase = .connected
      $0.projects = TestServer.projects
    }
    await store.receive(.delegate(.projects(TestServer.server, TestServer.projects, TestServer.info)))

    events.push(.phase(.resynchronizing))
    await store.receive(.streamPhase(.resynchronizing)) {
      $0.phase = .reconnecting
    }
    await store.receive(.streamResynchronized(result: .success(refreshed))) {
      $0.projects = refreshed
    }
    await store.receive(.delegate(.projects(TestServer.server, refreshed, TestServer.info)))
    #expect(script.projectCalls.count == 2)

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }
  }

  @Test("leaving the foreground cancels the connection and returning re-races it")
  func lifecycleRestarts() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(.refreshFinished(generation: 1_001, result: .success(TestServer.projects)))
    #expect(store.state.phase == .connected)

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }

    await store.send(.scenePhaseChanged(isActive: true)) {
      $0.isInForeground = true
    }
    await store.receive(.healthFinished(generation: 1_002, result: .success(probe()))) {
      $0.phase = .loading
    }
    await store.receive(.refreshFinished(generation: 1_002, result: .success(TestServer.projects))) {
      $0.phase = .connected
    }

    #expect(script.healthCalls.count == 2)
    #expect(script.projectCalls.count == 2)
  }

  @Test("a stale attempt generation cannot replace the current server")
  func staleAttemptIsIgnored() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 4, server: TestServer.server))

    let stale = ServerLinkProbe(
      server: TestServer.other,
      info: TestServer.info,
      candidates: 1,
      elapsedMilliseconds: 0
    )
    await store.send(.healthFinished(generation: 4, result: .success(stale)))
    #expect(store.state.server == TestServer.server)
    #expect(store.state.phase == .connecting)
    #expect(script.healthCalls.count == 0)
  }
}
