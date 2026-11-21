import ComposableArchitecture
import Foundation
#if canImport(UIKit)
  import UIKit
#endif

/// Every haptic the app plays, named by what it means. Answer the press, not the animation;
/// navigation and closing stay quiet.
public enum Haptic: String, CaseIterable, Sendable {
  case tap
  case lightTap
  case selection
  case confirm
  case cancel
  case threshold
  case snap
  case attention
  case success
  case warning
  case error

  /// How each moment feels, as platform-neutral data.
  public var feedback: HapticFeedback {
    switch self {
    case .tap: .impact(style: .light, intensity: 1)
    case .lightTap: .selection
    case .selection: .selection
    case .confirm: .impact(style: .medium, intensity: 0.75)
    case .cancel: .impact(style: .soft, intensity: 0.85)
    case .threshold: .impact(style: .light, intensity: 1)
    case .snap: .impact(style: .soft, intensity: 0.7)
    case .attention: .impact(style: .rigid, intensity: 0.7)
    case .success: .notification(.success)
    case .warning: .notification(.warning)
    case .error: .notification(.error)
    }
  }
}

public enum HapticImpactStyle: String, CaseIterable, Sendable {
  case light
  case medium
  case heavy
  case soft
  case rigid
}

public enum HapticNotificationKind: String, CaseIterable, Sendable {
  case success
  case warning
  case error
}

public enum HapticFeedback: Equatable, Sendable {
  case selection
  case impact(style: HapticImpactStyle, intensity: Double)
  case notification(HapticNotificationKind)
}

/// Plays the vocabulary. Reducers and views share this one seam; tests get a client that records
/// nothing and touches no hardware.
public struct HapticsClient: Sendable {
  public var play: @Sendable (Haptic) -> Void
  public var prepare: @Sendable (Haptic) -> Void

  public init(
    play: @escaping @Sendable (Haptic) -> Void = { _ in },
    prepare: @escaping @Sendable (Haptic) -> Void = { _ in }
  ) {
    self.play = play
    self.prepare = prepare
  }

  /// Records nothing and touches no hardware.
  public static let inert = HapticsClient()
}

extension HapticsClient: DependencyKey {
  public static let liveValue = HapticsClient.live()
  public static let testValue = HapticsClient.inert
}

extension DependencyValues {
  public var haptics: HapticsClient {
    get { self[HapticsClient.self] }
    set { self[HapticsClient.self] = newValue }
  }
}

extension HapticsClient {
  public static func live() -> HapticsClient {
    #if canImport(UIKit)
      return HapticsClient(
        play: { haptic in onMainActor { LiveHapticsEngine.shared.play(haptic) } },
        prepare: { haptic in onMainActor { LiveHapticsEngine.shared.prepare(haptic) } }
      )
    #else
      return .inert
    #endif
  }
}

/// The feedback generators are main-actor bound, so a request from a background effect hops to the
/// main actor and a request already there runs synchronously.
private func onMainActor(_ work: @escaping @MainActor @Sendable () -> Void) {
  if Thread.isMainThread {
    MainActor.assumeIsolated { work() }
  } else {
    Task { @MainActor in work() }
  }
}

#if canImport(UIKit)
  @MainActor
  private final class LiveHapticsEngine {
    static let shared = LiveHapticsEngine()

    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    private var impacts: [HapticImpactStyle: UIImpactFeedbackGenerator] = [:]

    func play(_ haptic: Haptic) {
      guard isAppActive else { return }

      switch haptic.feedback {
      case .selection:
        selection.selectionChanged()
      case .impact(let style, let intensity):
        impact(style).impactOccurred(intensity: intensity)
      case .notification(let kind):
        notification.notificationOccurred(kind.feedbackType)
      }
    }

    func prepare(_ haptic: Haptic) {
      switch haptic.feedback {
      case .selection:
        selection.prepare()
      case .impact(let style, _):
        impact(style).prepare()
      case .notification:
        notification.prepare()
      }
    }

    private func impact(_ style: HapticImpactStyle) -> UIImpactFeedbackGenerator {
      if let existing = impacts[style] { return existing }
      let generator = UIImpactFeedbackGenerator(style: style.feedbackStyle)
      impacts[style] = generator
      return generator
    }

    private var isAppActive: Bool {
      UIApplication.shared.applicationState == .active
    }
  }

  extension HapticImpactStyle {
    fileprivate var feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
      switch self {
      case .light: .light
      case .medium: .medium
      case .heavy: .heavy
      case .soft: .soft
      case .rigid: .rigid
      }
    }
  }

  extension HapticNotificationKind {
    fileprivate var feedbackType: UINotificationFeedbackGenerator.FeedbackType {
      switch self {
      case .success: .success
      case .warning: .warning
      case .error: .error
      }
    }
  }
#endif
