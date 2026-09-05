import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("KeysymTableSearch")
struct KeysymTableSearchTests {
  /// A synthetic QWERTY-shaped table: 3 keycodes starting at 38 (a
  /// realistic X11 keycode for physical "A" on a real US layout), 2
  /// keysyms per keycode (unshifted, shifted) — row 0 is 'a'/'A', row 1 is
  /// 'v'/'V' (standing in for whatever physical key produces v on this
  /// "layout"), row 2 is 'c'/'C'.
  private let qwertyTable: [UInt32] = [
    0x61, 0x41,  // 'a', 'A'
    0x76, 0x56,  // 'v', 'V'
    0x63, 0x43,  // 'c', 'C'
  ]

  @Test("finds an unshifted (level 0) match")
  func findsUnshiftedMatch() {
    let result = KeysymTableSearch.findKeycode(
      forKeysym: 0x76, in: qwertyTable, firstKeycode: 38, keysymsPerKeycode: 2)
    #expect(result == ResolvedKey(x11Keycode: 39, requiresShift: false))
  }

  @Test("finds a shifted (level 1) match and reports requiresShift")
  func findsShiftedMatch() {
    let result = KeysymTableSearch.findKeycode(
      forKeysym: 0x56, in: qwertyTable, firstKeycode: 38, keysymsPerKeycode: 2)
    #expect(result == ResolvedKey(x11Keycode: 39, requiresShift: true))
  }

  @Test("Dvorak-shaped table: v moves to a different physical keycode")
  func dvorakShiftedLayout() {
    // On Dvorak, the physical key at keycode 38 (where QWERTY has 'a')
    // produces 'a' too (they happen to coincide) but 'v' lives elsewhere —
    // simulate it living at row 2 instead of row 1.
    let dvorakTable: [UInt32] = [
      0x61, 0x41,  // keycode 38: 'a', 'A'
      0x63, 0x43,  // keycode 39: 'c', 'C' (where QWERTY had 'v')
      0x76, 0x56,  // keycode 40: 'v', 'V'
    ]
    let result = KeysymTableSearch.findKeycode(
      forKeysym: 0x76, in: dvorakTable, firstKeycode: 38, keysymsPerKeycode: 2)
    #expect(result?.x11Keycode == 40)
  }

  @Test("never guesses: a keysym only present at group 1 (AltGr) is not returned")
  func rejectsNonZeroGroup() {
    // 4 keysyms per keycode: [group0-level0, group0-level1, group1-level0, group1-level1].
    // Put the target ONLY at index 2 (group 1) for the single keycode.
    let table: [UInt32] = [0x61, 0x41, 0x76, 0x56]
    let result = KeysymTableSearch.findKeycode(
      forKeysym: 0x76, in: table, firstKeycode: 38, keysymsPerKeycode: 4)
    #expect(result == nil)
  }

  @Test("returns nil when the keysym isn't present anywhere")
  func returnsNilWhenAbsent() {
    let result = KeysymTableSearch.findKeycode(
      forKeysym: 0x99, in: qwertyTable, firstKeycode: 38, keysymsPerKeycode: 2)
    #expect(result == nil)
  }

  @Test("returns nil for a degenerate zero keysymsPerKeycode rather than dividing by zero")
  func rejectsZeroKeysymsPerKeycode() {
    let result = KeysymTableSearch.findKeycode(
      forKeysym: 0x76, in: qwertyTable, firstKeycode: 38, keysymsPerKeycode: 0)
    #expect(result == nil)
  }
}
