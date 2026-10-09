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

  // T-PREVIEWJUMP1
  @Test("Every text preview shares one minimum width, at least the wrap width of its label")
  func previewMinWidth() {
    // 46 wrapped characters at ~9 px is ~414 px; the shared minimum must cover it so
    // text previews never differ in width (which let the compositor flip sides).
    #expect(PickerLayoutLimits.previewMinContentWidth >= 414)
    #expect(PickerLayoutLimits.previewMinContentWidth <= 560)
  }
}
