import OpenCodeCore
import Testing

@Suite("Type tokens")
struct TypeTokenTests {
  @Test("every role has a token")
  func everyRoleMaps() {
    for role in OpenCodeTextRole.allCases {
      let token = OpenCodeTypeTokens.token(for: role)
      #expect(OpenCodeTextStyle.allCases.contains(token.style))
    }
  }

  @Test("code and log roles use the monospaced system design")
  func monospacedRoles() {
    #expect(OpenCodeTypeTokens.isMonospaced(.code))
    #expect(OpenCodeTypeTokens.isMonospaced(.codeSmall))
    #expect(OpenCodeTypeTokens.isMonospaced(.log))
  }

  @Test("interface roles use the standard system design")
  func standardRoles() {
    for role in OpenCodeTextRole.allCases where role != .code && role != .codeSmall && role != .log {
      #expect(!OpenCodeTypeTokens.isMonospaced(role))
    }
  }
}

@Suite("Colour tokens")
struct ColourTokenTests {
  private let palette = OpenCodePalette.brand

  @Test("every semantic token resolves in both appearances")
  func everyTokenResolves() {
    for appearance in OpenCodeAppearance.allCases {
      for token in OpenCodeColorToken.allCases {
        let rgba = palette.rgba(token, in: appearance)
        #expect((0...1).contains(rgba.red))
        #expect((0...1).contains(rgba.green))
        #expect((0...1).contains(rgba.blue))
        #expect(rgba.alpha > 0)
      }
    }
  }

  @Test("body and primary text clear WCAG AA on the canvas")
  func textContrast() {
    for appearance in OpenCodeAppearance.allCases {
      let canvas = palette.rgba(.canvas, in: appearance)
      #expect(palette.rgba(.textBody, in: appearance).contrastRatio(against: canvas) >= 4.5)
      #expect(palette.rgba(.textPrimary, in: appearance).contrastRatio(against: canvas) >= 4.5)
    }
  }

  @Test("links clear WCAG AA on the canvas")
  func linkContrast() {
    for appearance in OpenCodeAppearance.allCases {
      let canvas = palette.rgba(.canvas, in: appearance)
      #expect(palette.rgba(.link, in: appearance).contrastRatio(against: canvas) >= 4.5)
    }
  }

  @Test("light and dark canvases differ")
  func appearancesDiffer() {
    #expect(palette.rgba(.canvas, in: .light) != palette.rgba(.canvas, in: .dark))
  }
}
