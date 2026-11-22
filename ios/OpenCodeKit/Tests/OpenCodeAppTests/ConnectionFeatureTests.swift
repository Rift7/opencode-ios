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

  private func token(attempt: Int, stream: Int) -> ConnectionFeature.Token {
    ConnectionFeature.Token(attempt: attempt, stream: stream)
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
    await store.receive(.healthFinished(attempt: 1_001, result: .success(probe()))) {
      $0.phase = .loading
      $0.info = TestServer.info
    }
    await store.receive(.delegate(.verified(TestServer.server, TestServer.info)))
    await store.receive(.streamPhase(token: token(attempt: 1_001, stream: 2), phase: .connected))
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects))) {
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
    await store.receive(.healthFinished(attempt: 1_001, result: .failure(failure))) {
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
    await store.receive(.healthFinished(attempt: 1_001, result: .failure(failure))) {
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
    await store.receive(.healthFinished(attempt: 1_001, result: .failure(failure))) {
      $0.phase = .failed
      $0.failure = .malformed(feature: "server info")
    }
    await store.receive(.delegate(.failed(.malformed(feature: "server info"))))
  }

  @Test("a known-offline path waits instead of claiming bad credentials")
  func offlineWaits() async {
    let state = ConnectionFeature.State(id: 1, server: TestServer.server, isOffline: false)
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    let store = store(script: script, state: state)

    await store.send(.networkPathChanged(.offline)) {
      $0.phase = .reconnecting
      $0.failure = nil
      $0.isOffline = true
    }
    #expect(script.healthCalls.count == 0)
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
      $0.phase = .reconnecting
      $0.isOffline = true
    }
    await store.send(.networkPathChanged(.online)) {
      $0.phase = .connecting
      $0.isOffline = false
    }
    await store.receive(.healthFinished(attempt: 1_002, result: .success(probe())))
    #expect(store.state.server == TestServer.server)
    #expect(script.healthCalls.count == 1)
    await store.send(.scenePhaseChanged(isActive: false))
  }

  @Test("restoring while offline recovers when the path returns without a manual retry")
  func offlineRestoreRecovers() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let state = ConnectionFeature.State(id: 1, server: TestServer.server, isOffline: true)
    let store = store(script: script, state: state)

    await store.send(.task) {
      $0.phase = .reconnecting
    }
    #expect(script.healthCalls.count == 0)

    await store.send(.networkPathChanged(.online)) {
      $0.isOffline = false
      $0.phase = .connecting
    }
    await store.receive(.healthFinished(attempt: 1_002, result: .success(probe()))) {
      $0.phase = .loading
      $0.info = TestServer.info
    }
    await store.receive(.delegate(.verified(TestServer.server, TestServer.info)))
    await store.receive(.streamPhase(token: token(attempt: 1_002, stream: 3), phase: .connected))
    await store.receive(.refreshFinished(attempt: 1_002, result: .success(TestServer.projects))) {
      $0.phase = .connected
      $0.projects = TestServer.projects
    }
    await store.receive(.delegate(.projects(TestServer.server, TestServer.projects, TestServer.info)))
    #expect(script.healthCalls.count == 1)

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }
  }

  @Test("a path return while backgrounded does not start work")
  func backgroundPathReturnWaits() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let state = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .reconnecting,
      isOffline: true,
      isInForeground: false
    )
    let store = store(script: script, state: state)

    await store.send(.networkPathChanged(.online)) {
      $0.isOffline = false
    }
    #expect(script.healthCalls.count == 0)

    await store.send(.scenePhaseChanged(isActive: true)) {
      $0.isInForeground = true
      $0.phase = .connecting
    }
    await store.receive(.healthFinished(attempt: 1_002, result: .success(probe()))) {
      $0.phase = .loading
      $0.info = TestServer.info
    }
    await store.receive(.delegate(.verified(TestServer.server, TestServer.info)))
    await store.receive(.streamPhase(token: token(attempt: 1_002, stream: 3), phase: .connected))
    await store.receive(.refreshFinished(attempt: 1_002, result: .success(TestServer.projects))) {
      $0.phase = .connected
      $0.projects = TestServer.projects
    }
    await store.receive(.delegate(.projects(TestServer.server, TestServer.projects, TestServer.info)))
    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }
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
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects)))
    #expect(store.state.phase == .connected)

    let current = token(attempt: 1_001, stream: 2)
    await store.send(
      ConnectionFeature.Action.streamPhase(
        token: current,
        phase: .disconnected(OpenCodeClientError(.transport(.notSent)))
      )
    ) {
      $0.phase = .reconnecting
    }
    await store.send(ConnectionFeature.Action.streamPhase(token: current, phase: .connected))
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(refreshed))) {
      $0.phase = .connected
      $0.projects = refreshed
    }

    #expect(script.projectCalls.count == 2)
    await store.send(.scenePhaseChanged(isActive: false))
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
    await store.receive(.healthFinished(attempt: 1_001, result: .success(probe()))) {
      $0.phase = .loading
      $0.info = TestServer.info
    }
    await store.receive(.delegate(.verified(TestServer.server, TestServer.info)))
    let current = token(attempt: 1_001, stream: 2)

    events.push(.phase(.connected))
    await store.receive(.streamPhase(token: current, phase: .connected))
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects))) {
      $0.phase = .connected
      $0.projects = TestServer.projects
    }
    await store.receive(.delegate(.projects(TestServer.server, TestServer.projects, TestServer.info)))

    events.push(.phase(.resynchronizing))
    await store.receive(.streamPhase(token: current, phase: .resynchronizing)) {
      $0.phase = .reconnecting
    }
    await store.receive(.streamResynchronized(token: current, result: .success(refreshed))) {
      $0.projects = refreshed
    }
    await store.receive(.delegate(.projects(TestServer.server, refreshed, TestServer.info)))
    await store.receive(.delegate(.resynchronized(TestServer.server)))
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
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects)))
    #expect(store.state.phase == .connected)

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }

    await store.send(.scenePhaseChanged(isActive: true)) {
      $0.isInForeground = true
      $0.phase = .reconnecting
    }
    await store.receive(.healthFinished(attempt: 1_003, result: .success(probe()))) {
      $0.phase = .loading
    }
    await store.receive(.refreshFinished(attempt: 1_003, result: .success(TestServer.projects))) {
      $0.phase = .connected
    }

    #expect(script.healthCalls.count == 2)
    #expect(script.projectCalls.count == 2)
    await store.send(.scenePhaseChanged(isActive: false))
  }

  @Test("a stale attempt cannot replace the current server")
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
    await store.send(.healthFinished(attempt: 4, result: .success(stale)))
    #expect(store.state.server == TestServer.server)
    #expect(store.state.phase == .connecting)
    #expect(script.healthCalls.count == 0)
  }

  @Test("retry invalidates a delayed stream callback")
  func retryInvalidatesStreamCallbacks() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects)))
    let old = token(attempt: 1_001, stream: 2)

    await store.send(.retryTapped)
    await store.send(.streamPhase(token: old, phase: .ended(OpenCodeClientError(.status(401)))))
    await store.send(.streamResynchronized(token: old, result: .success([])))
    await store.send(
      .streamEvent(
        token: old,
        event: .projectUpdated(ServerProject(id: "late", name: "Late", directory: "/work/late"))
      )
    )

    #expect(store.state.failure == nil)
    #expect(store.state.projects == TestServer.projects)
    await store.send(.scenePhaseChanged(isActive: false))
  }

  @Test("path loss invalidates a delayed stream callback")
  func pathLossInvalidatesStreamCallbacks() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects)])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects)))
    let old = token(attempt: 1_001, stream: 2)

    await store.send(.networkPathChanged(.offline)) {
      $0.isOffline = true
      $0.phase = .reconnecting
    }
    await store.send(.streamPhase(token: old, phase: .ended(OpenCodeClientError(.status(401)))))
    await store.send(.streamResynchronized(token: old, result: .success([])))

    #expect(store.state.failure == nil)
    #expect(store.state.projects == TestServer.projects)
  }

  @Test("delayed stream and refresh callbacks from cancelled work are ignored")
  func delayedCallbacksAreIgnored() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success(TestServer.projects), .success([])])
    )
    let store = store(script: script, state: ConnectionFeature.State(id: 1, server: TestServer.server))
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(.refreshFinished(attempt: 1_001, result: .success(TestServer.projects)))
    let old = token(attempt: 1_001, stream: 2)

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.phase = .reconnecting
      $0.isInForeground = false
    }
    let projectsBefore = store.state.projects

    await store.send(.healthFinished(attempt: 1_001, result: .success(probe())))
    await store.send(.refreshFinished(attempt: 1_001, result: .success([])))
    await store.send(
      .streamPhase(token: old, phase: .ended(OpenCodeClientError(.status(401))))
    )
    await store.send(
      .streamEvent(
        token: old,
        event: .projectUpdated(
          ServerProject(id: "late", name: "Late", directory: "/work/late")
        )
      )
    )
    await store.send(.streamResynchronized(token: old, result: .success([])))

    #expect(store.state.phase == .reconnecting)
    #expect(store.state.failure == nil)
    #expect(store.state.projects == projectsBefore)
    #expect(store.state.isInForeground == false)
  }
}
