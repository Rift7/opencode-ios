import SwiftUI

/// A colour value independent of any colour space API, so palette data stays testable.
public struct OpenCodeRGBA: Sendable, Equatable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// Parses `#RRGGBB` or `#RRGGBBAA`.
  public init(hex: String) {
    var value = hex
    if value.hasPrefix("#") { value.removeFirst() }
    let digits = UInt64(value, radix: 16) ?? 0
    let hasAlpha = value.count == 8
    red = Double((digits >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    green = Double((digits >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    blue = Double((digits >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    alpha = hasAlpha ? Double(digits & 0xFF) / 255 : 1
  }

  /// WCAG 2.x relative luminance.
  public var relativeLuminance: Double {
    func linear(_ component: Double) -> Double {
      component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG 2.x contrast ratio against another opaque colour.
  public func contrastRatio(against other: OpenCodeRGBA) -> Double {
    let a = relativeLuminance
    let b = other.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}

/// Semantic colour names. Views ask for meaning, not for a hex value.
public enum OpenCodeColorToken: String, CaseIterable, Sendable {
  case canvas
  case canvasWeak
  case codeBand
  case userBubble
  case surfaceStrong
  case textStrong
  case textPrimary
  case textBody
  case textWeak
  case textTertiary
  case border
  case borderStrong
  case accent
  case link
  case signal
  case danger
  case success
  case warning
}

public enum OpenCodeAppearance: String, CaseIterable, Sendable {
  case light
  case dark
}

/// The brand palette, expressed as semantic tokens in both appearances.
///
/// Values follow the desktop design tokens the app is built around: a near-neutral canvas, a
/// monochrome accent, a blue link, and state colours for diffs. Light values are darkened enough
/// to clear WCAG AA on the canvas.
public struct OpenCodePalette: Sendable {
  public let light: [OpenCodeColorToken: OpenCodeRGBA]
  public let dark: [OpenCodeColorToken: OpenCodeRGBA]

  public func rgba(_ token: OpenCodeColorToken, in appearance: OpenCodeAppearance) -> OpenCodeRGBA {
    let table = appearance == .light ? light : dark
    precondition(table[token] != nil, "missing \(token) in \(appearance)")
    return table[token] ?? OpenCodeRGBA(red: 0, green: 0, blue: 0)
  }

  public static let brand = OpenCodePalette(
    light: [
      .canvas: OpenCodeRGBA(hex: "#FFFFFF"),
      .canvasWeak: OpenCodeRGBA(hex: "#FAFAFA"),
      .codeBand: OpenCodeRGBA(hex: "#FAFAFA"),
      .userBubble: OpenCodeRGBA(hex: "#F2F2F2"),
      .surfaceStrong: OpenCodeRGBA(hex: "#EEEEEE"),
      .textStrong: OpenCodeRGBA(hex: "#0A0A0A"),
      .textPrimary: OpenCodeRGBA(hex: "#161616"),
      .textBody: OpenCodeRGBA(hex: "#242424"),
      .textWeak: OpenCodeRGBA(hex: "#5C5C5C"),
      .textTertiary: OpenCodeRGBA(hex: "#6E6E6E"),
      .border: OpenCodeRGBA(hex: "#E6E6E6"),
      .borderStrong: OpenCodeRGBA(hex: "#CCCCCC"),
      .accent: OpenCodeRGBA(hex: "#242424"),
      .link: OpenCodeRGBA(hex: "#3A5BF6"),
      .signal: OpenCodeRGBA(hex: "#3A5BF6"),
      .danger: OpenCodeRGBA(hex: "#B82D35"),
      .success: OpenCodeRGBA(hex: "#17813E"),
      .warning: OpenCodeRGBA(hex: "#9A5B00")
    ],
    dark: [
      .canvas: OpenCodeRGBA(hex: "#161616"),
      .canvasWeak: OpenCodeRGBA(hex: "#101010"),
      .codeBand: OpenCodeRGBA(hex: "#1C1C1C"),
      .userBubble: OpenCodeRGBA(hex: "#2E2E2E"),
      .surfaceStrong: OpenCodeRGBA(hex: "#3A3A3A"),
      .textStrong: OpenCodeRGBA(hex: "#FAFAFA"),
      .textPrimary: OpenCodeRGBA(hex: "#EDEDED"),
      .textBody: OpenCodeRGBA(hex: "#DDDDDD"),
      .textWeak: OpenCodeRGBA(hex: "#AEAEAE"),
      .textTertiary: OpenCodeRGBA(hex: "#8A8A8A"),
      .border: OpenCodeRGBA(hex: "#2D2D2D"),
      .borderStrong: OpenCodeRGBA(hex: "#454545"),
      .accent: OpenCodeRGBA(hex: "#DBDBDB"),
      .link: OpenCodeRGBA(hex: "#A2BCFF"),
      .signal: OpenCodeRGBA(hex: "#A2BCFF"),
      .danger: OpenCodeRGBA(hex: "#F17471"),
      .success: OpenCodeRGBA(hex: "#6BD586"),
      .warning: OpenCodeRGBA(hex: "#F0B45F")
    ]
  )
}

@MainActor
public enum OpenCodeColors {
  public static func color(_ token: OpenCodeColorToken) -> Color {
    #if canImport(UIKit)
      return Color(
        uiColor: UIColor { traits in
          let appearance: OpenCodeAppearance = traits.userInterfaceStyle == .dark ? .dark : .light
          let rgba = OpenCodePalette.brand.rgba(token, in: appearance)
          return UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
      )
    #else
      let rgba = OpenCodePalette.brand.rgba(token, in: .light)
      return Color(red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    #endif
  }
}
