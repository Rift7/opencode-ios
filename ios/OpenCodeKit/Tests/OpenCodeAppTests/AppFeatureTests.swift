import ComposableArchitecture
import OpenCodeApp
import OpenCodeCore
import Testing

@MainActor
@Suite("App feature")
struct AppFeatureTests {
  @Test("connecting moves through loading to connected")
  func connectReachesConnected() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.connectionProbe = ConnectionProbe { .success(()) }
    }

    await store.send(.connectTapped) {
      $0.phase = .loading
    }
    await store.receive(.probeFinished(.reachable)) {
      $0.phase = .connected
    }
  }

  @Test("a failed probe surfaces the failure")
  func failureSurfaces() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.connectionProbe = ConnectionProbe { .failure(.unreachable) }
    }

    await store.send(.connectTapped) {
      $0.phase = .loading
    }
    await store.receive(.probeFinished(.failed(.unreachable))) {
      $0.phase = .failed(.unreachable)
    }
  }

  @Test("retry while loading is ignored")
  func retryWhileLoadingIsIgnored() async {
    let store = TestStore(initialState: AppFeature.State(phase: .loading)) {
      AppFeature()
    }

    await store.send(.retryTapped)
  }

  @Test("a missing configuration is reported, not guessed")
  func notConfiguredFailure() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.connectionProbe = ConnectionProbe { .failure(.notConfigured) }
    }

    await store.send(.connectTapped) {
      $0.phase = .loading
    }
    await store.receive(.probeFinished(.failed(.notConfigured))) {
      $0.phase = .failed(.notConfigured)
    }
  }
}
