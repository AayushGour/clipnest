// GTKScrollIntoViewTests.swift
//
// T-KBSCROLL1. See GTKKeyEventMappingTests.swift's top doc comment for the
// `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency note.
import Testing

@testable import ClipnestGTK

@Suite("ScrollIntoView")
struct GTKScrollIntoViewTests {
  // 30 rows of 50px = 1500 content, 300px viewport.
  private func target(value: Double, rowIndex: Int) -> Double {
    ScrollIntoView.targetValue(
      value: value, pageSize: 300, upper: 1500, rowTop: Double(rowIndex) * 50, rowHeight: 50)
  }

  @Test("A fully visible row leaves the scroll alone")
  func visibleRowDoesNotMove() {
    #expect(target(value: 100, rowIndex: 4) == 100)  // 200-250, inside 100-400
    #expect(target(value: 100, rowIndex: 2) == 100)  // flush with the top
    #expect(target(value: 100, rowIndex: 7) == 100)  // flush with the bottom (350-400)
  }

  @Test("A row below the viewport scrolls just enough to align its bottom")
  func rowBelowAlignsBottom() {
    // Row 8 = 400-450; viewport 100-400 -> value 150.
    #expect(target(value: 100, rowIndex: 8) == 150)
  }

  @Test("A row above the viewport aligns its top")
  func rowAboveAlignsTop() {
    #expect(target(value: 100, rowIndex: 1) == 50)
  }

  @Test("Jumping far (End / wrap-around) lands on the clamped extreme")
  func farJumpsClamp() {
    #expect(target(value: 0, rowIndex: 29) == 1200)  // bottom: upper - pageSize
    #expect(target(value: 1200, rowIndex: 0) == 0)  // wrap to top
  }

  @Test("A row taller than the viewport aligns its top")
  func tallRowAlignsTop() {
    #expect(
      ScrollIntoView.targetValue(
        value: 0, pageSize: 100, upper: 1000, rowTop: 400, rowHeight: 250) == 400)
  }

  @Test("Content shorter than the viewport never scrolls")
  func shortContentStaysAtZero() {
    #expect(
      ScrollIntoView.targetValue(
        value: 0, pageSize: 300, upper: 200, rowTop: 150, rowHeight: 50) == 0)
  }

  @Test("Before layout (pageSize 0) the value is returned untouched")
  func unlaidOutIsNoOp() {
    #expect(
      ScrollIntoView.targetValue(
        value: 42, pageSize: 0, upper: 0, rowTop: 500, rowHeight: 50) == 42)
  }
}
