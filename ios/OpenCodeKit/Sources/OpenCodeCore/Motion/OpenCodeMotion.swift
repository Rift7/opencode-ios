import CoreGraphics
import SwiftUI

/// Which half of a role's motion is playing: arriving or leaving.
public enum OpenCodeMotionPhase: String, CaseIterable, Sendable {
  case enter
  case exit
}

/// A curve one role resolves to. The numbers are data, so the vocabulary is testable without
/// animating anything.
public enum OpenCodeMotionCurve: Equatable, Sendable {
  case spring(duration: Double, bounce: Double)
  case easeOut(duration: Double)
  case easeInOut(duration: Double)

  public var duration: Double {
    switch self {
    case .spring(let duration, _), .easeOut(let duration), .easeInOut(let duration):
      duration
    }
  }

  public var bounce: Double {
    if case .spring(_, let bounce) = self { return bounce }
    return 0
  }
}

extension OpenCodeMotionCurve {
  public var animation: Animation {
    switch self {
    case .spring(let duration, let bounce):
      .spring(duration: duration, bounce: bounce)
    case .easeOut(let duration):
      .easeOut(duration: duration)
    case .easeInOut(let duration):
      .easeInOut(duration: duration)
    }
  }
}

/// The app's motion roles. A role names a moment; it never carries numbers at the call site.
public enum OpenCodeMotionRole: String, CaseIterable, Sendable {
  case press
  case microIn
  case microOut
  case swap
  case layout
  case collapse
  case panelOpen
  case panelClose
  case surface
  case release
  case flight
  case keyboard
  case dim
  case reduced

  /// The role's curve for `phase`.
  public func curve(phase: OpenCodeMotionPhase = .enter) -> OpenCodeMotionCurve {
    switch self {
    case .press:
      phase == .enter ? .easeOut(duration: 0.10) : .spring(duration: 0.26, bounce: 0.15)
    case .microIn:
      phase == .enter
        ? .spring(duration: 0.26, bounce: 0.15)
        : .spring(duration: 0.18, bounce: 0)
    case .microOut:
      .spring(duration: 0.18, bounce: 0)
    case .swap:
      .easeOut(duration: phase == .enter ? 0.22 : 0.14)
    case .layout:
      phase == .enter
        ? .spring(duration: 0.34, bounce: 0)
        : .spring(duration: 0.26, bounce: 0)
    case .collapse:
      .spring(duration: 0.26, bounce: 0)
    case .panelOpen:
      phase == .enter
        ? .spring(duration: 0.40, bounce: 0.10)
        : .spring(duration: 0.30, bounce: 0)
    case .panelClose:
      .spring(duration: 0.30, bounce: 0)
    case .surface:
      .spring(duration: 0.44, bounce: 0)
    case .release:
      .spring(duration: 2 * Double.pi / 28.5, bounce: 0)
    case .flight:
      .spring(duration: 0.38, bounce: 0)
    case .keyboard:
      .spring(duration: 0.267, bounce: 0)
    case .dim:
      .easeOut(duration: 0.32)
    case .reduced:
      OpenCodeMotion.reducedFade
    }
  }

  /// The curve the app actually plays. Reduce Motion drops travel, scale and bounce but keeps a
  /// short fade rather than cutting the change.
  public func curve(
    phase: OpenCodeMotionPhase,
    reduceMotion: Bool
  ) -> OpenCodeMotionCurve {
    reduceMotion ? OpenCodeMotion.reducedFade : curve(phase: phase)
  }
}

/// The shared motion vocabulary: reduce-motion policy, geometry and stagger.
public enum OpenCodeMotion {
  /// The one curve every role becomes under Reduce Motion.
  public static let reducedFade = OpenCodeMotionCurve.easeInOut(duration: 0.20)

  /// Press-down scale for buttons. Rows, tabs and bubbles answer with a highlight instead.
  public static let pressScale: Double = 0.97

  /// A glyph or badge arriving.
  public static let microInScale: Double = 0.85

  /// Content swapping in place, and everything leaving.
  public static let swapScale: Double = 0.96

  /// Subtle vertical rise for arriving rows and labels.
  public static let entranceRise: CGFloat = 6

  /// Subtle blur for compact capsules and arriving glyphs.
  public static let blurSubtle: CGFloat = 3

  /// Per-item delay across a staggered group, capped so a long list still starts promptly.
  public static let staggerStep: Double = 0.02
  public static let staggerCap: Double = 0.10

  public static func staggerDelay(index: Int) -> Double {
    min(Double(max(index, 0)) * staggerStep, staggerCap)
  }
}

/// The single Reduce Motion translation: movement, scale, blur and rotation go neutral and only
/// opacity changes.
public enum OpenCodeMotionReduce {
  public static func offset(_ value: CGFloat, reduceMotion: Bool) -> CGFloat {
    reduceMotion ? 0 : value
  }

  public static func offset(_ value: CGSize, reduceMotion: Bool) -> CGSize {
    reduceMotion ? .zero : value
  }

  public static func scale(_ value: Double, reduceMotion: Bool) -> Double {
    reduceMotion ? 1 : value
  }

  public static func blur(_ value: CGFloat, reduceMotion: Bool) -> CGFloat {
    reduceMotion ? 0 : value
  }

  public static func rotation(_ value: Double, reduceMotion: Bool) -> Double {
    reduceMotion ? 0 : value
  }
}

/// Where a view sits before it arrives or after it leaves. `identity` is at rest.
public struct OpenCodeMotionPose: Equatable, Sendable {
  public var opacity: Double
  public var scale: Double
  public var blur: CGFloat
  public var offset: CGSize

  public init(opacity: Double = 1, scale: Double = 1, blur: CGFloat = 0, offset: CGSize = .zero) {
    self.opacity = opacity
    self.scale = scale
    self.blur = blur
    self.offset = offset
  }

  public static let identity = OpenCodeMotionPose()

  /// A small glyph or badge arriving.
  public static var microIn: OpenCodeMotionPose {
    OpenCodeMotionPose(opacity: 0, scale: OpenCodeMotion.microInScale, blur: OpenCodeMotion.blurSubtle)
  }

  /// Content swapping in place, and everything leaving.
  public static var swap: OpenCodeMotionPose {
    OpenCodeMotionPose(opacity: 0, scale: OpenCodeMotion.swapScale, blur: OpenCodeMotion.blurSubtle)
  }

  /// `swap` shifted vertically: a value rolling over like a counter.
  public static func roll(distance: CGFloat) -> OpenCodeMotionPose {
    var pose = swap
    pose.offset = CGSize(width: 0, height: distance)
    return pose
  }

  public static func entering(_ role: OpenCodeMotionRole) -> OpenCodeMotionPose {
    switch role {
    case .microIn, .press: .microIn
    default: .swap
    }
  }

  public static func leaving(_ role: OpenCodeMotionRole) -> OpenCodeMotionPose {
    .swap
  }

  /// Under Reduce Motion only the opacity survives.
  public func reduced(reduceMotion: Bool) -> OpenCodeMotionPose {
    reduceMotion ? OpenCodeMotionPose(opacity: opacity) : self
  }

  /// The pose `fraction` of the way from identity.
  public func scaled(by fraction: Double) -> OpenCodeMotionPose {
    OpenCodeMotionPose(
      opacity: 1 - (1 - opacity) * fraction,
      scale: 1 - (1 - scale) * fraction,
      blur: blur * CGFloat(fraction),
      offset: CGSize(
        width: offset.width * CGFloat(fraction),
        height: offset.height * CGFloat(fraction)
      )
    )
  }
}
