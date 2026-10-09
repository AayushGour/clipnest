// GTKPickerLayoutLimitsTests.swift
//
// T-ROWLINES1. See GTKKeyEventMappingTests.swift's top doc comment for the
// ClipnestPlatformLinuxTests -> ClipnestGTK manifest-dependency note.
import Testing

@testable import ClipnestGTK

@Suite("PickerLayoutLimits")
struct GTKPickerLayoutLimitsTests {
  @Test("Rows are capped at three lines")
  func rowCap() {
    #expect(PickerLayoutLimits.rowTextMaxLines == 3)
  }

  @Test("The Linux window is taller than macOS's 420 but not absurdly so")
  func windowHeight() {
    #expect(PickerLayoutLimits.windowDefaultHeight > 420)
    #expect(PickerLayoutLimits.windowDefaultHeight <= 600)
  }

  @Test("The preview is bounded well below a typical screen height")
  func previewBounded() {
    #expect(PickerLayoutLimits.previewMaxContentHeight > 0)
    #expect(PickerLayoutLimits.previewMaxContentHeight < 1080)
  }
}
