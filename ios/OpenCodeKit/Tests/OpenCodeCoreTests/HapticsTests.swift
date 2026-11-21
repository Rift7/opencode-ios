import ComposableArchitecture
import OpenCodeCore
import Synchronization
import Testing

private final class HapticRecorder: Sendable {
  private let played = Mutex<[Haptic]>([])
  private let prepared = Mutex<[Haptic]>([])

  func play(_ haptic: Haptic) {
    played.withLock { $0.append(haptic) }
  }

  func prepare(_ haptic: Haptic) {
    prepared.withLock { $0.append(haptic) }
  }

  var playedHaptics: [Haptic] { played.withLock { $0 } }
  var preparedHaptics: [Haptic] { prepared.withLock { $0 } }
}

private struct HapticsProbe {
  @Dependency(\.haptics) var haptics
}

@Suite("Haptics")
struct HapticsTests {
  @Test("the vocabulary keeps the eleven stable names")
  func vocabularyIsStable() {
    #expect(
      Haptic.allCases.map(\.rawValue) == [
        "tap", "lightTap", "selection", "confirm", "cancel", "threshold", "snap",
        "attention", "success", "warning", "error",
      ]
    )
  }

  @Test("each haptic keeps its audited feel")
  func feedbackTable() {
    #expect(Haptic.tap.feedback == .impact(style: .light, intensity: 1))
    #expect(Haptic.lightTap.feedback == .selection)
    #expect(Haptic.selection.feedback == .selection)
    #expect(Haptic.confirm.feedback == .impact(style: .medium, intensity: 0.75))
    #expect(Haptic.cancel.feedback == .impact(style: .soft, intensity: 0.85))
    #expect(Haptic.threshold.feedback == .impact(style: .light, intensity: 1))
    #expect(Haptic.snap.feedback == .impact(style: .soft, intensity: 0.7))
    #expect(Haptic.attention.feedback == .impact(style: .rigid, intensity: 0.7))
    #expect(Haptic.success.feedback == .notification(.success))
    #expect(Haptic.warning.feedback == .notification(.warning))
    #expect(Haptic.error.feedback == .notification(.error))
  }

  @Test("every impact intensity is a fraction the platform accepts")
  func intensitiesAreFractions() {
    for haptic in Haptic.allCases {
      if case .impact(_, let intensity) = haptic.feedback {
        #expect((0...1).contains(intensity))
        #expect(intensity > 0)
      }
    }
  }

  @Test("an injected client receives exactly what was played and prepared")
  func injectionReachesTheClient() async {
    let recorder = HapticRecorder()

    withDependencies {
      $0.haptics = HapticsClient(
        play: { recorder.play($0) },
        prepare: { recorder.prepare($0) }
      )
    } operation: {
      let haptics = HapticsProbe().haptics
      haptics.prepare(.confirm)
      haptics.play(.confirm)
      haptics.play(.error)
    }

    #expect(recorder.preparedHaptics == [.confirm])
    #expect(recorder.playedHaptics == [.confirm, .error])
  }

  @Test("the test value plays and prepares every haptic without hardware")
  func testValueIsInert() async {
    for haptic in Haptic.allCases {
      HapticsClient.testValue.prepare(haptic)
      HapticsClient.testValue.play(haptic)
    }

    await Task.detached {
      HapticsClient.testValue.play(.attention)
    }.value
  }

  @Test("a haptics override does not leak past its scope")
  func overrideDoesNotLeak() async {
    let recorder = HapticRecorder()

    withDependencies {
      $0.haptics = HapticsClient(play: { recorder.play($0) })
    } operation: {
      HapticsProbe().haptics.play(.tap)
    }

    HapticsProbe().haptics.play(.tap)

    #expect(recorder.playedHaptics == [.tap])
  }
}
