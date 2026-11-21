import SwiftUI

/// The platform text style a role maps to. Pure data so the mapping is testable.
public enum OpenCodeTextStyle: String, CaseIterable, Sendable {
  case largeTitle
  case title
  case title2
  case title3
  case headline
  case body
  case callout
  case subheadline
  case footnote
  case caption
  case caption2
}

public enum OpenCodeFontWeight: String, CaseIterable, Sendable {
  case regular
  case medium
  case semibold
  case bold
}

public enum OpenCodeFontDesign: String, CaseIterable, Sendable {
  case standard
  case monospaced
}

public struct OpenCodeTypeToken: Sendable, Equatable {
  public let style: OpenCodeTextStyle
  public let weight: OpenCodeFontWeight
  public let design: OpenCodeFontDesign
}

/// Semantic text roles. Interface roles use the system font; code and log roles use the system
/// monospaced font. No font file is bundled.
public enum OpenCodeTextRole: String, CaseIterable, Sendable {
  case largeTitle
  case title
  case title2
  case title3
  case headline
  case body
  case callout
  case subheadline
  case footnote
  case caption
  case caption2
  case code
  case codeSmall
  case log
}

public enum OpenCodeTypeTokens {
  public static func token(for role: OpenCodeTextRole) -> OpenCodeTypeToken {
    switch role {
    case .largeTitle: OpenCodeTypeToken(style: .largeTitle, weight: .regular, design: .standard)
    case .title: OpenCodeTypeToken(style: .title, weight: .regular, design: .standard)
    case .title2: OpenCodeTypeToken(style: .title2, weight: .regular, design: .standard)
    case .title3: OpenCodeTypeToken(style: .title3, weight: .regular, design: .standard)
    case .headline: OpenCodeTypeToken(style: .headline, weight: .semibold, design: .standard)
    case .body: OpenCodeTypeToken(style: .body, weight: .regular, design: .standard)
    case .callout: OpenCodeTypeToken(style: .callout, weight: .regular, design: .standard)
    case .subheadline: OpenCodeTypeToken(style: .subheadline, weight: .regular, design: .standard)
    case .footnote: OpenCodeTypeToken(style: .footnote, weight: .regular, design: .standard)
    case .caption: OpenCodeTypeToken(style: .caption, weight: .regular, design: .standard)
    case .caption2: OpenCodeTypeToken(style: .caption2, weight: .regular, design: .standard)
    case .code: OpenCodeTypeToken(style: .subheadline, weight: .regular, design: .monospaced)
    case .codeSmall: OpenCodeTypeToken(style: .footnote, weight: .regular, design: .monospaced)
    case .log: OpenCodeTypeToken(style: .caption, weight: .regular, design: .monospaced)
    }
  }

  public static func isMonospaced(_ role: OpenCodeTextRole) -> Bool {
    token(for: role).design == .monospaced
  }
}

@MainActor
public enum OpenCodeFonts {
  public static func font(_ role: OpenCodeTextRole) -> Font {
    let token = OpenCodeTypeTokens.token(for: role)
    return Font.system(style(token.style), design: design(token.design)).weight(weight(token.weight))
  }

  private static func style(_ style: OpenCodeTextStyle) -> Font.TextStyle {
    switch style {
    case .largeTitle: .largeTitle
    case .title: .title
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .body: .body
    case .callout: .callout
    case .subheadline: .subheadline
    case .footnote: .footnote
    case .caption: .caption
    case .caption2: .caption2
    }
  }

  private static func weight(_ weight: OpenCodeFontWeight) -> Font.Weight {
    switch weight {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }

  private static func design(_ design: OpenCodeFontDesign) -> Font.Design {
    switch design {
    case .standard: .default
    case .monospaced: .monospaced
    }
  }
}
