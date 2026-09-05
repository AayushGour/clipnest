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

  @Test("Ctrl+Enter is NOT the plain-text variant — Control isn't Alt")
  func controlEnterStaysNonPlain() {
    #expect(
      KeyEventMapping.action(keyval: Self.returnKey, state: Self.controlMask)
        == .commit(plainText: false))
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

  @Test("Ctrl+Delete deletes; plain Delete does nothing")
  func ctrlDeleteDeletes() {
    #expect(KeyEventMapping.action(keyval: Self.delete, state: Self.controlMask) == .delete)
    #expect(KeyEventMapping.action(keyval: Self.delete, state: 0) == nil)
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
}
