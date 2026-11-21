import CoreGraphics

/// The spacing grid, in points. Prefer these to literals so layouts stay on the same scale.
public enum OpenCodeSpacing {
  public static let s1: CGFloat = 1
  public static let s2: CGFloat = 2
  public static let s4: CGFloat = 4
  public static let s6: CGFloat = 6
  public static let s8: CGFloat = 8
  public static let s10: CGFloat = 10
  public static let s12: CGFloat = 12
  public static let s14: CGFloat = 14
  public static let s16: CGFloat = 16
  public static let s18: CGFloat = 18
  public static let s20: CGFloat = 20
  public static let s24: CGFloat = 24
  public static let s32: CGFloat = 32

  /// Screen and list-row horizontal inset.
  public static let screenHorizontal: CGFloat = s16

  /// Default stack spacing between related items.
  public static let stack: CGFloat = s8

  /// Between groups and sections.
  public static let group: CGFloat = s12

  /// Every step of the grid, so a layout audit can prove nothing invented a value.
  public static let grid: [CGFloat] = [
    s1, s2, s4, s6, s8, s10, s12, s14, s16, s18, s20, s24, s32,
  ]
}

/// Corner radii, in points. Small on purpose: flat surfaces with hairline borders, not capsules.
public enum OpenCodeRadius {
  /// Tiny marks: inline code, checkbox insets.
  public static let xs: CGFloat = 4
  /// Small fills and thumbnails.
  public static let sm: CGFloat = 6
  /// Tertiary-fill fields and rows.
  public static let fill: CGFloat = 8
  /// Inline controls and trays.
  public static let control: CGFloat = 8
  /// Cards.
  public static let card: CGFloat = 10
  /// Attachment chips, clipped media, settings tiles.
  public static let tile: CGFloat = 10
  /// Large panels.
  public static let panel: CGFloat = 12
  /// Sheets, scanner frame, voice panel.
  public static let sheet: CGFloat = 16

  public static let all: [CGFloat] = [xs, sm, fill, control, card, tile, panel, sheet]

  /// A corner's radius is at most half its height, so an animated shape cannot over-round.
  public static func clamp(_ radius: CGFloat, height: CGFloat) -> CGFloat {
    min(max(0, radius), max(0, height) / 2)
  }
}
