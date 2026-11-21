import Foundation
import OpenCodeCore
import Testing

@Suite("Motion vocabulary")
struct MotionTests {
  @Test("the fourteen roles keep their stable names")
  func roleNamesAreStable() {
    #expect(
      OpenCodeMotionRole.allCases.map(\.rawValue) == [
        "press", "microIn", "microOut", "swap", "layout", "collapse", "panelOpen",
        "panelClose", "surface", "release", "flight", "keyboard", "dim", "reduced",
      ]
    )
  }

  @Test("every role resolves a positive curve in both phases")
  func everyRoleResolves() {
    for role in OpenCodeMotionRole.allCases {
      for phase in OpenCodeMotionPhase.allCases {
        let curve = role.curve(phase: phase)
        #expect(curve.duration > 0)
        #expect(curve.duration < 1)
        #expect((0...1).contains(curve.bounce))
      }
    }
  }

  @Test("leaving is quicker than arriving where the role has both")
  func exitsAreShorter() {
    for role in [OpenCodeMotionRole.swap, .layout, .panelOpen, .microIn] {
      #expect(role.curve(phase: .exit).duration < role.curve(phase: .enter).duration)
    }
  }

  @Test("reduce motion collapses every role to the one short fade")
  func reduceMotionCollapsesRoles() {
    for role in OpenCodeMotionRole.allCases {
      for phase in OpenCodeMotionPhase.allCases {
        #expect(role.curve(phase: phase, reduceMotion: true) == OpenCodeMotion.reducedFade)
      }
    }

    #expect(OpenCodeMotion.reducedFade == .easeInOut(duration: 0.20))
    #expect(OpenCodeMotion.reducedFade.bounce == 0)
  }

  @Test("a pose under reduce motion keeps opacity and nothing else")
  func reduceMotionKeepsOnlyOpacity() {
    let swap = OpenCodeMotionPose.swap

    #expect(swap.opacity == 0)
    #expect(swap.scale == OpenCodeMotion.swapScale)
    #expect(swap.blur > 0)

    let reduced = swap.reduced(reduceMotion: true)
    #expect(reduced.opacity == 0)
    #expect(reduced.scale == 1)
    #expect(reduced.blur == 0)
    #expect(reduced.offset == .zero)
    #expect(OpenCodeMotionPose.identity.reduced(reduceMotion: true) == .identity)
  }

  @Test("the reduce helpers neutralise movement but not the value that stays")
  func reduceHelpers() {
    #expect(OpenCodeMotionReduce.offset(CGFloat(12), reduceMotion: true) == 0)
    #expect(OpenCodeMotionReduce.offset(CGFloat(12), reduceMotion: false) == 12)
    #expect(OpenCodeMotionReduce.offset(CGSize(width: 4, height: 9), reduceMotion: true) == .zero)
    #expect(OpenCodeMotionReduce.offset(CGSize(width: 4, height: 9), reduceMotion: false) == CGSize(width: 4, height: 9))
    #expect(OpenCodeMotionReduce.scale(0.8, reduceMotion: true) == 1)
    #expect(OpenCodeMotionReduce.scale(0.8, reduceMotion: false) == 0.8)
    #expect(OpenCodeMotionReduce.blur(8, reduceMotion: true) == 0)
    #expect(OpenCodeMotionReduce.blur(8, reduceMotion: false) == 8)
    #expect(OpenCodeMotionReduce.rotation(45, reduceMotion: true) == 0)
    #expect(OpenCodeMotionReduce.rotation(45, reduceMotion: false) == 45)
  }

  @Test("a pose scaled by one is itself and by zero is at rest")
  func poseScaling() {
    let micro = OpenCodeMotionPose.microIn

    #expect(micro.scaled(by: 1) == micro)
    #expect(micro.scaled(by: 0) == .identity)
    #expect(micro.scaled(by: 0.5).opacity == 0.5)
  }

  @Test("rolling poses carry a vertical offset")
  func rollPose() {
    let roll = OpenCodeMotionPose.roll(distance: 5)

    #expect(roll.offset == CGSize(width: 0, height: 5))
    #expect(roll.opacity == 0)
  }

  @Test("the press scale barely moves and never inverts")
  func pressScale() {
    #expect(OpenCodeMotion.pressScale >= 0.9)
    #expect(OpenCodeMotion.pressScale < 1)
    #expect(OpenCodeMotion.entranceRise > 0)
  }

  @Test("stagger delays start at zero and stop growing at the cap")
  func staggerIsBounded() {
    #expect(OpenCodeMotion.staggerDelay(index: 0) == 0)
    #expect(OpenCodeMotion.staggerDelay(index: -3) == 0)
    #expect(OpenCodeMotion.staggerDelay(index: 1) == OpenCodeMotion.staggerStep)
    #expect(OpenCodeMotion.staggerDelay(index: 3) > OpenCodeMotion.staggerDelay(index: 2))
    #expect(OpenCodeMotion.staggerDelay(index: 100) == OpenCodeMotion.staggerCap)
  }
}
