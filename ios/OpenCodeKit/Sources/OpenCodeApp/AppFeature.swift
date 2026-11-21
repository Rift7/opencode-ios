import ComposableArchitecture
import Foundation
import OpenCodeCore

/// Where the app is in its launch sequence. Only `disconnected`, `loading` and `failed` are
/// reachable in this scaffold; `connected` is wired in the networking phase.
public enum LaunchPhase: Equatable, Sendable {
  case disconnected
  case loading
  case failed(ProbeFailure)
  case connected
}

public enum ProbeOutcome: Equatable, Sendable {
  case reachable
  case failed(ProbeFailure)
}

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var phase: LaunchPhase

    public init(phase: LaunchPhase = .disconnected) {
      self.phase = phase
    }
  }

  public enum Action: Equatable, Sendable {
    case connectTapped
    case retryTapped
    case probeFinished(ProbeOutcome)
  }

  @Dependency(\.connectionProbe) private var probe

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .connectTapped, .retryTapped:
        guard state.phase != .loading else { return .none }
        state.phase = .loading
        let probe = probe
        return .run { send in
          let result = await probe.check()
          switch result {
          case .success:
            await send(.probeFinished(.reachable))
          case .failure(let failure):
            await send(.probeFinished(.failed(failure)))
          }
        }

      case .probeFinished(.reachable):
        state.phase = .connected
        return .none

      case .probeFinished(.failed(let failure)):
        state.phase = .failed(failure)
        return .none
      }
    }
  }
}
