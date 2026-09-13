import Foundation

/// The physical modifier keys `ModifierReleaseWaiter` cares about.
public struct ModifierMask: OptionSet, Sendable, Equatable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let control = ModifierMask(rawValue: 1 << 0)
  public static let shift = ModifierMask(rawValue: 1 << 1)
  public static let alt = ModifierMask(rawValue: 1 << 2)
  public static let superKey = ModifierMask(rawValue: 1 << 3)
}

/// Reads the CURRENT physical modifier-key state, injected so
/// `ModifierReleaseWaiter`'s poll loop is testable without a real X
/// display. On X11 the production implementation
/// (`X11ModifierMaskReader`) uses `XQueryPointer`, and — because a real
/// X11 session's XQueryPointer genuinely does reflect physical modifier
/// state — `LinuxEventSynthesizerFactory` still wires it through
/// `WaitForReleaseModifierGuard` for `.x11` sessions.
///
/// **The Wayland gap (T-MODWAIT-WAYLAND1, 2026-09-14 — routed around, NOT
/// resolved; see the correction below):** there is no client-side API at
/// all for reading physical modifier state on native Wayland — only the
/// compositor knows it. Worse, and measured rather than reasoned about
/// (T-COPYFLAKE1, 2026-09-13): on a GNOME Wayland session XWayland IS
/// reachable, so before this fix the factory picked `X11ModifierMaskReader`,
/// not `NullModifierMaskReader` — and that reader is blind in exactly the
/// same way while REPORTING SUCCESS: with a native-Wayland window focused,
/// `XQueryPointer` returns success with an empty state mask even while
/// Shift/Super are physically held (8/8 probe samples, independently
/// reproduced again at 8/8 during the fix). So on the single most common
/// Linux desktop configuration this protocol's production conformance
/// silently answered "nothing held", always, and `ModifierReleaseWaiter`
/// was inert rather than absent.
///
/// The fix that landed does not give this protocol a Wayland conformance at
/// all — no read of this shape can be made trustworthy on Wayland from a
/// client process, compositor-companion or not. What is REAL and worth
/// keeping: `LinuxEventSynthesizerFactory` stopped choosing a reader by
/// display reachability (which silently handed a native-Wayland session
/// this protocol's lying X11 answer whenever XWayland happened to be up)
/// and now branches on `SessionType` directly, so `.wayland`/`.unknown`
/// sessions never consult this protocol's wrong X11 answer again. In its
/// place they get `ForceReleaseModifierGuard` (`ModifierGuarding.swift`),
/// which blindly releases every tracked modifier keycode through uinput
/// before each chord instead of asking a reader anything — **but that
/// replacement strategy was itself later measured ineffective at the
/// actual merge problem (T-CROSSDEVICE-MODIFIER1, 2026-09-14): Mutter
/// tracks modifier state per originating device, so a release posted from
/// Clipnest's own uinput device cannot clear a modifier the user's
/// physical keyboard is still asserting — see that type's own doc comment
/// for the measurements. It is kept only because it is harmless, not
/// because it fixes the merge.** `NullModifierMaskReader` remains in place
/// as the pre-existing, narrower fallback for the case this file's
/// `WaitForReleaseModifierGuard` branch still uses this protocol for: an
/// `.x11` session where `XOpenDisplay` itself failed (no X server reachable
/// at all) — unrelated to the Wayland gap above.
///
/// Both conformances still share one defect this protocol's SHAPE
/// permits: `currentModifierMask()` has no way to say "I cannot tell". Any
/// FUTURE conformance should arrive together with a third state, or it is
/// free to repeat this exact mistake silently.
public protocol ModifierMaskReading: Sendable {
  func currentModifierMask() -> ModifierMask
}
