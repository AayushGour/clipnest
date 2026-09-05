import CXlib
import Foundation

/// Real, `XQueryPointer`-backed `ModifierMaskReading` — reads the state
/// mask returned alongside the pointer position, which `XQueryPointer`
/// reports honoring the CURRENT physical modifier keys regardless of which
/// window has focus. Manual-verify only: no X server in the CI container
/// this ships to.
///
/// Assumes the common `Mod1Mask` = Alt / `Mod4Mask` = Super convention —
/// true for every mainstream desktop's default modifier mapping. A user
/// who has remapped these via `xmodmap` could see a stale reading; a fully
/// correct implementation would resolve them via `XGetModifierMapping`
/// instead of this fixed assumption, which is out of scope here (nothing
/// else in this module needs remapped-modifier awareness).
/// `@unchecked Sendable`: `Display*` (`OpaquePointer`) isn't inherently
/// Sendable, matching `X11ClipboardConnection`'s same documented exception
/// elsewhere in this module — Xlib calls on one connection are expected to
/// come from a single owner, never concurrently.
public final class X11ModifierMaskReader: ModifierMaskReading, @unchecked Sendable {
  private let display: OpaquePointer

  public init(display: OpaquePointer) {
    self.display = display
  }

  public func currentModifierMask() -> ModifierMask {
    let root = XDefaultRootWindow(display)
    var returnedRoot: Window = 0
    var returnedChild: Window = 0
    var rootX: Int32 = 0
    var rootY: Int32 = 0
    var winX: Int32 = 0
    var winY: Int32 = 0
    var state: UInt32 = 0
    guard
      XQueryPointer(
        display, root, &returnedRoot, &returnedChild, &rootX, &rootY, &winX, &winY, &state) != 0
    else { return [] }

    var mask: ModifierMask = []
    if state & UInt32(ControlMask) != 0 { mask.insert(.control) }
    if state & UInt32(ShiftMask) != 0 { mask.insert(.shift) }
    if state & UInt32(Mod1Mask) != 0 { mask.insert(.alt) }
    if state & UInt32(Mod4Mask) != 0 { mask.insert(.superKey) }
    return mask
  }
}

/// Documented fallback when no `ModifierMaskReading` source is available at
/// all (pure Wayland with no reachable X display) — see
/// `ModifierMaskReading`'s doc comment for the known gap this stands in for
/// until a Wayland Shell-extension companion (a separate, not-yet-built
/// task) can supply a real reading over its own IPC channel.
public struct NullModifierMaskReader: ModifierMaskReading {
  public init() {}
  public func currentModifierMask() -> ModifierMask { [] }
}
