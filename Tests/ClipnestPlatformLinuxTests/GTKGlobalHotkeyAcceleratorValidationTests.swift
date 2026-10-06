// GTKGlobalHotkeyAcceleratorValidationTests.swift
//
// T-OPT2 (Linux port, GTK4 view layer). Exercises
// `GlobalHotkeyAcceleratorValidation.validate(keyval:state:)`/
// `.displayLabel(for:)` (`Sources/ClipnestGTK/Support/
// GlobalHotkeyAcceleratorValidation.swift`) — real `gtk_accelerator_valid`/
// `gtk_accelerator_name`/`gtk_accelerator_parse`/`gtk_accelerator_get_label`
// calls, but none of them touch a display, a window, or GSettings/dconf, so
// these run identically in a headless `swift test` container (verified
// empirically against a real `swift:6.0-jammy` + `libgtk-4-dev` build
// before writing this file, not assumed) — same reasoning as
// `GTKKeyEventMappingTests.swift`'s top doc comment for the sibling
// `ClipnestGTK` -> `ClipnestPlatformLinuxTests` manifest dependency.
import Testing

@testable import ClipnestGTK

@Suite("GlobalHotkeyAcceleratorValidation")
struct GTKGlobalHotkeyAcceleratorValidationTests {
  // GDK modifier-state bits — same ABI-stable values `KeyEventMapping.swift`
  // and `GTKKeyEventMappingTests.swift` already hardcode.
  private static let controlMask: UInt32 = 1 << 2
  private static let altMask: UInt32 = 1 << 3
  private static let shiftMask: UInt32 = 1 << 0
  private static let superMask: UInt32 = 1 << 26

  // GDK keysyms (`gdk/gdkkeysyms.h`).
  private static let vKey: UInt32 = 0x076
  private static let upKey: UInt32 = 0xff52
  private static let shiftLKey: UInt32 = 0xffe1
  private static let controlLKey: UInt32 = 0xffe3
  private static let superLKey: UInt32 = 0xffeb

  @Test("A bare, unmodified printable key is rejected — .noModifier")
  func bareKeyRejected() {
    let result = GlobalHotkeyAcceleratorValidation.validate(keyval: Self.vKey, state: 0)
    #expect(result == .failure(.noModifier))
  }

  @Test("keyval == 0 (no real key captured) is rejected — .empty")
  func emptyKeyvalRejected() {
    let result = GlobalHotkeyAcceleratorValidation.validate(keyval: 0, state: Self.superMask)
    #expect(result == .failure(.empty))
  }

  @Test("Super+Shift+V is accepted and returns the canonical accelerator name")
  func superShiftVAccepted() {
    let result = GlobalHotkeyAcceleratorValidation.validate(
      keyval: Self.vKey, state: Self.superMask | Self.shiftMask)
    #expect(result == .success("<Shift><Super>v"))
  }

  @Test("Ctrl+Alt+V is accepted")
  func ctrlAltVAccepted() {
    let result = GlobalHotkeyAcceleratorValidation.validate(
      keyval: Self.vKey, state: Self.controlMask | Self.altMask)
    #expect(result == .success("<Control><Alt>v"))
  }

  @Test("An unmodified arrow key is rejected — .noModifier (GTK's own invalid-unmodified list too)")
  func unmodifiedArrowKeyRejected() {
    let result = GlobalHotkeyAcceleratorValidation.validate(keyval: Self.upKey, state: 0)
    #expect(result == .failure(.noModifier))
  }

  @Test("A modified arrow key is accepted")
  func modifiedArrowKeyAccepted() {
    let result = GlobalHotkeyAcceleratorValidation.validate(
      keyval: Self.upKey, state: Self.controlMask)
    #expect(result == .success("<Control>Up"))
  }

  @Test("A bare modifier keyval, state 0, is rejected — before gtk_accelerator_valid even runs")
  func bareModifierKeyvalWithNoStateRejected() {
    #expect(
      GlobalHotkeyAcceleratorValidation.validate(keyval: Self.shiftLKey, state: 0)
        == .failure(.noModifier))
  }

  @Test(
    "A modifier keyval fired while ANOTHER modifier is already held is still rejected — .notAnAccelerator (GTK's own invalid_accelerator_vals, e.g. holding Ctrl then pressing Shift)"
  )
  func modifierKeyvalWithAnotherModifierHeldRejected() {
    #expect(
      GlobalHotkeyAcceleratorValidation.validate(keyval: Self.shiftLKey, state: Self.controlMask)
        == .failure(.notAnAccelerator))
    #expect(
      GlobalHotkeyAcceleratorValidation.validate(keyval: Self.controlLKey, state: Self.shiftMask)
        == .failure(.notAnAccelerator))
    #expect(
      GlobalHotkeyAcceleratorValidation.validate(keyval: Self.superLKey, state: Self.shiftMask)
        == .failure(.notAnAccelerator))
  }

  @Test("Extra unrelated modifier bits (e.g. a mouse-button chord bit) don't block a valid combo")
  func extraUnrelatedBitsIgnored() {
    // Bit 8 (1 << 8) is GDK_BUTTON1_MASK — irrelevant to this recorder;
    // `modifierMask` only looks at Control/Alt/Shift/Super.
    let result = GlobalHotkeyAcceleratorValidation.validate(
      keyval: Self.vKey, state: Self.superMask | (1 << 8))
    #expect(result == .success("<Super>v"))
  }

  @Test("displayLabel formats a stored accelerator for display")
  func displayLabelFormatsStoredAccelerator() {
    #expect(
      GlobalHotkeyAcceleratorValidation.displayLabel(for: "<Super><Shift>v") == "Shift+Super+V")
  }

  @Test("displayLabel returns nil for garbage or an empty string")
  func displayLabelRejectsUnparsable() {
    #expect(GlobalHotkeyAcceleratorValidation.displayLabel(for: "not-an-accelerator") == nil)
    #expect(GlobalHotkeyAcceleratorValidation.displayLabel(for: "") == nil)
  }
}
