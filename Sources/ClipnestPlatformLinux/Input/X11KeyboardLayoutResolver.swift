import CXlib
import Foundation

/// Real, X11-backed `KeyboardLayoutResolving` — queries the X server's
/// CURRENT keyboard mapping via `XGetKeyboardMapping`, which reflects
/// whatever layout is active right now, including under XWayland (which
/// keeps its keymap synced from the Wayland compositor in every mainstream
/// desktop).
///
/// Manual-verify only: there is no X server in the CI container this ships
/// to, so this type's live behavior is never exercised by `swift test` —
/// only `KeysymTableSearch` above (the actual mapping-search logic) is
/// unit-tested, with a synthetic table standing in for a real display's
/// mapping.
///
/// On pure Wayland with no reachable X display (`XOpenDisplay` fails),
/// `resolve(character:)` always returns `nil` — there is no keymap source
/// available to this module in that case (see `ModifierMaskReading`'s doc
/// comment for the same gap on the modifier-mask side), so every caller
/// falls back to clipboard-only rather than guess, per this stack's
/// "never guess" rule.
/// `@unchecked Sendable`: `Display*` (`OpaquePointer`) isn't inherently
/// Sendable, matching `X11ClipboardConnection`'s same documented exception
/// elsewhere in this module — Xlib calls on one connection are expected to
/// come from a single owner, never concurrently.
public final class X11KeyboardLayoutResolver: KeyboardLayoutResolving, @unchecked Sendable {
  private let display: OpaquePointer?

  /// - Parameter display: an already-open `Display*` (as returned by
  ///   `XOpenDisplay(nil)`), owned by the caller — this type never opens or
  ///   closes it, mirroring `X11ModifierMaskReader`'s convention of sharing
  ///   one connection rather than every collaborator opening its own.
  public init(display: OpaquePointer?) {
    self.display = display
  }

  public func resolve(character: Character) -> ResolvedKey? {
    guard let display, let keysym = Latin1Keysym.keysym(for: character) else { return nil }

    var minKeycode: Int32 = 0
    var maxKeycode: Int32 = 0
    XDisplayKeycodes(display, &minKeycode, &maxKeycode)
    guard maxKeycode >= minKeycode, minKeycode >= 0, minKeycode <= 255 else { return nil }

    var keysymsPerKeycode: Int32 = 0
    let keycodeCount = maxKeycode - minKeycode + 1
    guard
      let rawTable = XGetKeyboardMapping(
        display, UInt8(minKeycode), keycodeCount, &keysymsPerKeycode)
    else { return nil }
    defer { XFree(UnsafeMutableRawPointer(rawTable)) }

    let totalEntries = Int(keycodeCount) * Int(keysymsPerKeycode)
    var table = [UInt32](repeating: 0, count: totalEntries)
    for index in 0..<totalEntries {
      table[index] = UInt32(truncatingIfNeeded: rawTable[index])
    }

    return KeysymTableSearch.findKeycode(
      forKeysym: keysym, in: table, firstKeycode: minKeycode, keysymsPerKeycode: keysymsPerKeycode)
  }
}
