import OpenCodeCore
import Testing

@Suite("Layout tokens")
struct LayoutTokenTests {
  @Test("the spacing grid is ascending, unique and whole points")
  func gridIsWellFormed() {
    let grid = OpenCodeSpacing.grid

    #expect(grid.count == 13)
    #expect(grid.first == 1)
    #expect(grid.last == 32)
    #expect(grid == grid.sorted())
    #expect(Set(grid).count == grid.count)
    for value in grid {
      #expect(value > 0)
      #expect(value == value.rounded())
    }
  }

  @Test("the semantic spacing aliases are grid steps")
  func aliasesAreOnTheGrid() {
    #expect(OpenCodeSpacing.screenHorizontal == OpenCodeSpacing.s16)
    #expect(OpenCodeSpacing.stack == OpenCodeSpacing.s8)
    #expect(OpenCodeSpacing.group == OpenCodeSpacing.s12)

    for alias in [
      OpenCodeSpacing.screenHorizontal, OpenCodeSpacing.stack, OpenCodeSpacing.group,
    ] {
      #expect(OpenCodeSpacing.grid.contains(alias))
    }
  }

  @Test("radius tokens follow the small-radius scale")
  func radiiFollowTheScale() {
    #expect(OpenCodeRadius.xs == 4)
    #expect(OpenCodeRadius.sm == 6)
    #expect(OpenCodeRadius.fill == 8)
    #expect(OpenCodeRadius.control == 8)
    #expect(OpenCodeRadius.card == 10)
    #expect(OpenCodeRadius.tile == 10)
    #expect(OpenCodeRadius.panel == 12)
    #expect(OpenCodeRadius.sheet == 16)
  }

  @Test("no radius is larger than a sheet and none is negative")
  func radiiAreOrdered() {
    let all = OpenCodeRadius.all

    #expect(all == all.sorted())
    #expect(all.first == OpenCodeRadius.xs)
    #expect(all.last == OpenCodeRadius.sheet)
    for value in all {
      #expect(value >= 0)
    }
  }

  @Test("a corner never rounds beyond half its height")
  func radiusClamp() {
    #expect(OpenCodeRadius.clamp(10, height: 100) == 10)
    #expect(OpenCodeRadius.clamp(10, height: 12) == 6)
    #expect(OpenCodeRadius.clamp(-4, height: 20) == 0)
    #expect(OpenCodeRadius.clamp(8, height: 0) == 0)
    #expect(OpenCodeRadius.clamp(8, height: -20) == 0)
  }
}
