import Foundation

/// Pure keysym-table search, extracted from `X11KeyboardLayoutResolver` so
/// it is unit-testable without a live X display — there is no X server in
/// the CI container this ships to.
///
/// `table` is shaped exactly like `XGetKeyboardMapping`'s flat return
/// buffer: `table[row * keysymsPerKeycode + level]`, where row 0
/// corresponds to `firstKeycode`.
///
/// Levels `0` and `1` are group 0 (unshifted / Shift) — the only levels
/// this stack will ever request a modifier for. A match only found at
/// level 2 or higher (group 1 — AltGr and beyond on most layouts) is
/// deliberately NOT returned: `KeyboardLayoutResolving`'s contract is
/// "never guess," and this stack has no way to hold AltGr as part of a
/// paste chord.
public enum KeysymTableSearch {
  public static func findKeycode(
    forKeysym target: UInt32,
    in table: [UInt32],
    firstKeycode: Int32,
    keysymsPerKeycode: Int32
  ) -> ResolvedKey? {
    guard keysymsPerKeycode > 0, !table.isEmpty else { return nil }
    let levelsToCheck = min(2, Int(keysymsPerKeycode))
    let rowCount = table.count / Int(keysymsPerKeycode)
    for row in 0..<rowCount {
      let base = row * Int(keysymsPerKeycode)
      for level in 0..<levelsToCheck where table[base + level] == target {
        return ResolvedKey(x11Keycode: firstKeycode + Int32(row), requiresShift: level == 1)
      }
    }
    return nil
  }
}
