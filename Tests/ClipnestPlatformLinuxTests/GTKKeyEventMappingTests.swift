// GTKKeyEventMappingTests.swift
//
// P7-D (Linux port, GTK4 view layer). Exercises `KeyEventMapping.action(
// keyval:state:)` (`Sources/ClipnestGTK/Support/KeyEventMapping.swift`) —
// pure integer arithmetic, no GTK/display dependency. See this task's
// return message / senior-dev log for a note on `ClipnestPlatformLinuxTests`'
// current `Package.swift` dependency list, which does not yet include
// `ClipnestGTK` — this file (and every other `GTK*Tests.swift` file) will
// not build until that one-line manifest addition lands; the assertions
// below are written and reviewed as if it already had.
import Testing

@testable import ClipnestGTK

@Suite("KeyEventMapping")
struct GTKKeyEventMappingTests {
  private static let controlMask: UInt32 = 1 << 2
  private static let altMask: UInt32 = 1 << 3
  private static let shiftMask: UInt32 = 1 << 0
  private static let lockMask: UInt32 = 1 << 1
  private static let superMask: UInt32 = 1 << 26

  private static let up: UInt32 = 0xff52
  private static let down: UInt32 = 0xff54
  private static let returnKey: UInt32 = 0xff0d
  private static let kpEnter: UInt32 = 0xff8d
  private static let escape: UInt32 = 0xff1b
  private static let fLower: UInt32 = 0x066
  private static let fUpper: UInt32 = 0x046
  private static let pLower: UInt32 = 0x070
  private static let delete: UInt32 = 0xffff
  private static let one: UInt32 = 0x031
  private static let two: UInt32 = 0x032
  private static let three: UInt32 = 0x033
  private static let unboundKey: UInt32 = 0x061  // 'a'
  // Keyboard-parity pass (routed follow-up): keyvals for the four new
  // Ctrl-chords (Ctrl+S/Ctrl+N/Ctrl+Shift+E/Ctrl+,).
  private static let sLower: UInt32 = 0x073
  private static let sUpper: UInt32 = 0x053
  private static let nLower: UInt32 = 0x06e
  private static let nUpper: UInt32 = 0x04e
  private static let eLower: UInt32 = 0x065
  private static let eUpper: UInt32 = 0x045
  private static let comma: UInt32 = 0x02c

  @Test("Up/Down move regardless of modifiers")
  func upDownMove() {
    #expect(KeyEventMapping.action(keyval: Self.up, state: 0) == .moveUp)
    #expect(KeyEventMapping.action(keyval: Self.down, state: 0) == .moveDown)
    #expect(KeyEventMapping.action(keyval: Self.up, state: Self.shiftMask) == .moveUp)
  }

  @Test("Enter commits with plainText false; numpad Enter is identical")
  func enterCommitsPlain() {
    #expect(KeyEventMapping.action(keyval: Self.returnKey, state: 0) == .commit(plainText: false))
    #expect(KeyEventMapping.action(keyval: Self.kpEnter, state: 0) == .commit(plainText: false))
  }

  @Test("Alt+Enter commits with plainText true")
  func altEnterCommitsPlainText() {
    #expect(
      KeyEventMapping.action(keyval: Self.returnKey, state: Self.altMask)
        == .commit(plainText: true))
  }

  // MARK: - T-BUG1 (parity-audit bug #4): modified Return must never alias
  // plain Return silently — mirrors macOS's `PickerView.returnAction(for:)`
  // fix for the identical defect.

  @Test("Ctrl+Enter is ignored — Control isn't Alt, and must NOT silently alias plain Return")
  func controlEnterIsIgnored() {
    #expect(KeyEventMapping.action(keyval: Self.returnKey, state: Self.controlMask) == nil)
  }

  @Test("Shift+Enter is ignored, not aliased to plain Return")
  func shiftEnterIsIgnored() {
    #expect(KeyEventMapping.action(keyval: Self.returnKey, state: Self.shiftMask) == nil)
  }

  @Test("Super+Enter is ignored, not aliased to plain Return")
  func superEnterIsIgnored() {
    #expect(KeyEventMapping.action(keyval: Self.returnKey, state: Self.superMask) == nil)
  }

  @Test("Numpad Enter with an unimplemented modifier is ignored too, same as plain Enter")
  func controlKPEnterIsIgnored() {
    #expect(KeyEventMapping.action(keyval: Self.kpEnter, state: Self.controlMask) == nil)
  }

  @Test("Alt wins over an accompanying unimplemented modifier — still commits plain text")
  func altPlusUnimplementedModifierStillCommitsPlainText() {
    #expect(
      KeyEventMapping.action(keyval: Self.returnKey, state: Self.altMask | Self.shiftMask)
        == .commit(plainText: true))
    #expect(
      KeyEventMapping.action(keyval: Self.returnKey, state: Self.altMask | Self.controlMask)
        == .commit(plainText: true))
  }

  @Test(
    "Lock (Caps/Shift Lock) alone doesn't disqualify a plain Enter — it's a toggle, not a held modifier"
  )
  func lockAloneStillCommitsPlain() {
    #expect(
      KeyEventMapping.action(keyval: Self.returnKey, state: Self.lockMask)
        == .commit(plainText: false))
  }

  @Test("Lock doesn't rescue an otherwise-unimplemented modifier combination")
  func lockDoesNotRescueUnimplementedModifier() {
    #expect(
      KeyEventMapping.action(keyval: Self.returnKey, state: Self.controlMask | Self.lockMask)
        == nil)
  }

  @Test("Escape always dismisses")
  func escapeDismisses() {
    #expect(KeyEventMapping.action(keyval: Self.escape, state: 0) == .dismiss)
  }

  @Test("Ctrl+F focuses search; plain F does nothing")
  func ctrlFFocusesSearch() {
    #expect(KeyEventMapping.action(keyval: Self.fLower, state: Self.controlMask) == .focusSearch)
    #expect(KeyEventMapping.action(keyval: Self.fUpper, state: Self.controlMask) == .focusSearch)
    #expect(KeyEventMapping.action(keyval: Self.fLower, state: 0) == nil)
  }

  @Test("Ctrl+P toggles pin; plain P does nothing")
  func ctrlPTogglesPin() {
    #expect(KeyEventMapping.action(keyval: Self.pLower, state: Self.controlMask) == .togglePin)
    #expect(KeyEventMapping.action(keyval: Self.pLower, state: 0) == nil)
  }

  // MARK: - Delete: bare Delete now works, Ctrl+Delete kept as an accepted
  // alias (see `KeyEventMapping.swift`'s own doc comment on this case for
  // why both are intentionally accepted, mirroring macOS's `PickerView
  // .handle(_:)` `.delete` case matching "regardless of modifiers").

  @Test("Plain Delete deletes — no modifier required, matching macOS parity")
  func plainDeleteDeletes() {
    #expect(KeyEventMapping.action(keyval: Self.delete, state: 0) == .delete)
  }

  @Test("Ctrl+Delete still deletes — kept as an accepted alias, not dropped")
  func ctrlDeleteStillDeletes() {
    #expect(KeyEventMapping.action(keyval: Self.delete, state: Self.controlMask) == .delete)
  }

  @Test("Delete deletes regardless of any other modifier bit held (Shift, Super, Lock)")
  func deleteDeletesRegardlessOfOtherModifiers() {
    #expect(KeyEventMapping.action(keyval: Self.delete, state: Self.shiftMask) == .delete)
    #expect(KeyEventMapping.action(keyval: Self.delete, state: Self.superMask) == .delete)
    #expect(KeyEventMapping.action(keyval: Self.delete, state: Self.lockMask) == .delete)
    #expect(
      KeyEventMapping.action(keyval: Self.delete, state: Self.controlMask | Self.shiftMask)
        == .delete)
  }

  @Test("Ctrl+1/2/3 switch tabs by index")
  func ctrlDigitsSwitchTabs() {
    #expect(
      KeyEventMapping.action(keyval: Self.one, state: Self.controlMask) == .switchTab(.one))
    #expect(
      KeyEventMapping.action(keyval: Self.two, state: Self.controlMask) == .switchTab(.two))
    #expect(
      KeyEventMapping.action(keyval: Self.three, state: Self.controlMask) == .switchTab(.three))
    #expect(KeyEventMapping.action(keyval: Self.one, state: 0) == nil)
  }

  @Test("An unbound key with no modifiers maps to nil")
  func unboundKeyMapsToNil() {
    #expect(KeyEventMapping.action(keyval: Self.unboundKey, state: 0) == nil)
  }

  @Test("Extra unrelated modifier bits (e.g. CapsLock) don't break a Ctrl-chord")
  func extraModifierBitsIgnored() {
    let lockMask: UInt32 = 1 << 1
    #expect(
      KeyEventMapping.action(keyval: Self.pLower, state: Self.controlMask | lockMask)
        == .togglePin)
  }

  // MARK: - Keyboard-parity pass (routed follow-up): Ctrl+S/Ctrl+N/
  // Ctrl+Shift+E/Ctrl+, — four more Ctrl-chords closing the gap where each
  // action was reachable only by mouse. Same lower/upper-case-both-match
  // coverage as `ctrlFFocusesSearch`/case-insensitivity above.

  @Test("Ctrl+S saves the highlighted item as a snippet; plain S does nothing")
  func ctrlSSavesAsSnippet() {
    #expect(
      KeyEventMapping.action(keyval: Self.sLower, state: Self.controlMask) == .saveAsSnippet)
    #expect(
      KeyEventMapping.action(keyval: Self.sUpper, state: Self.controlMask) == .saveAsSnippet)
    #expect(KeyEventMapping.action(keyval: Self.sLower, state: 0) == nil)
  }

  @Test("Ctrl+N opens the new-snippet form; plain N does nothing")
  func ctrlNOpensNewSnippetForm() {
    #expect(KeyEventMapping.action(keyval: Self.nLower, state: Self.controlMask) == .newSnippet)
    #expect(KeyEventMapping.action(keyval: Self.nUpper, state: Self.controlMask) == .newSnippet)
    #expect(KeyEventMapping.action(keyval: Self.nLower, state: 0) == nil)
  }

  @Test(
    "Ctrl+Shift+E replaces/edits the highlighted snippet; Ctrl+E alone and Shift+E alone do nothing"
  )
  func ctrlShiftEReplacesSnippet() {
    #expect(
      KeyEventMapping.action(keyval: Self.eLower, state: Self.controlMask | Self.shiftMask)
        == .replaceSnippet)
    #expect(
      KeyEventMapping.action(keyval: Self.eUpper, state: Self.controlMask | Self.shiftMask)
        == .replaceSnippet)
    #expect(KeyEventMapping.action(keyval: Self.eLower, state: Self.controlMask) == nil)
    #expect(KeyEventMapping.action(keyval: Self.eLower, state: Self.shiftMask) == nil)
    #expect(KeyEventMapping.action(keyval: Self.eLower, state: 0) == nil)
  }

  @Test("Ctrl+, opens Settings; plain comma does nothing")
  func ctrlCommaOpensSettings() {
    #expect(KeyEventMapping.action(keyval: Self.comma, state: Self.controlMask) == .openSettings)
    #expect(KeyEventMapping.action(keyval: Self.comma, state: 0) == nil)
  }
}
