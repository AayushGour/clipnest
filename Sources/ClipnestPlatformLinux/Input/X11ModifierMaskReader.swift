import CXlib
import Foundation

/// Real, `XQueryPointer`-backed `ModifierMaskReading` — reads the state
/// mask returned alongside the pointer position. Manual-verify only: no X
/// server in the CI container this ships to.
///
/// **CORRECTION (T-COPYFLAKE1, measured live 2026-09-13).** This comment
/// used to claim `XQueryPointer` "reports honoring the CURRENT physical
/// modifier keys regardless of which window has focus". That is TRUE on a
/// real X11 session and FALSE on a GNOME Wayland session, where this class
/// is nevertheless the reader `LinuxEventSynthesizerFactory` picks
/// (XWayland is running, so `XOpenDisplay` succeeds and the
/// `NullModifierMaskReader` branch is never taken). XWayland's core
/// keyboard state is only updated from the key events mutter forwards to
/// it, so with a native-Wayland window focused it never sees the user's
/// modifiers at all. Probed directly with Shift and then Super physically
/// held down by a uinput device: `XQueryPointer` returned SUCCESS with
/// `state == 0` on 8 of 8 samples.
///
/// The consequence is not a missing reading, it is a WRONG one:
/// `ModifierReleaseWaiter` reads `[]`, concludes "nothing is held", and
/// lets `UInputEventSynthesizer.post` fire its chord with the user's
/// hotkey modifiers still down — measured to turn a 0%-failure path into a
/// 100%-failure one for snippet expansion (see
/// `LinuxClipboardSelectionReplacer`'s own notes). This is the
/// coding-standards.md false-success family: a call that cannot express
/// "I do not know" is forced to answer "nothing held".
///
/// **PARTIALLY ADDRESSED for the uinput backend (T-MODWAIT-WAYLAND1,
/// 2026-09-14) — do not read this as "the Wayland problem is fixed," see
/// the correction below.** This class itself is unchanged and is still
/// correct — and still used — for real `.x11` sessions (see
/// `LinuxEventSynthesizerFactory`'s per-session-type branch); the fix does
/// not touch it. What is REAL: `LinuxEventSynthesizerFactory` now branches
/// on `SessionType` instead of display reachability, so it no longer
/// silently picks this class's wrong-on-Wayland answer just because
/// XWayland happens to be reachable — that specific lie (`success` with an
/// empty mask while modifiers are physically held) can no longer reach
/// `ModifierReleaseWaiter`. In its place, `.wayland`/`.unknown` sessions get
/// `ForceReleaseModifierGuard` (`ModifierGuarding.swift`), which posts an
/// unconditional uinput-level RELEASE of every tracked modifier keycode
/// before each chord instead of reading anything — **but that replacement
/// was itself later measured ineffective at the actual merge problem
/// (T-CROSSDEVICE-MODIFIER1, 2026-09-14): Mutter tracks modifier state per
/// originating device, so a release posted from Clipnest's own uinput
/// device cannot clear a modifier the user's physical keyboard is still
/// asserting — see that type's own doc comment for the measurements.** The
/// genuine fix here is narrower than it first looked: this class no longer
/// gets trusted where it lies; the cross-device modifier merge itself
/// remains open, tracked on the board as `T-CROSSDEVICE-MODIFIER1`.
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
