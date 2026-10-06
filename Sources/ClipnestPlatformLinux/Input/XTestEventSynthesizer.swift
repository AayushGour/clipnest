import CXlib
import ClipnestCore
import Foundation

/// XTEST-backed `EventSynthesizing`/`SyntheticKeystrokePosting`: posts
/// through `XTestFakeKeyEvent`, X11-only.
///
/// MUST NOT be constructed (or selected — see
/// `LinuxEventSynthesizerSelection`) on a Wayland session: XTEST only
/// reaches XWayland clients there, so native Wayland windows would
/// silently receive nothing at all — worse than a visible failure, since
/// the user would have no idea the paste never happened. `init?` itself
/// enforces this by returning `nil` on anything but `.x11`.
///
/// Manual-verify only: there is no X server in the CI container this ships
/// to — only the pure collaborators it's built from
/// (`KeysymTableSearch`, `ModifierReleaseWaiter`, `TerminalAppRegistry`)
/// are unit-tested.
/// `@unchecked Sendable`: `Display*` (`OpaquePointer`) isn't inherently
/// Sendable, matching `X11ClipboardConnection`'s same documented exception
/// elsewhere in this module — Xlib calls on one connection are expected to
/// come from a single owner, never concurrently.
public final class XTestEventSynthesizer: EventSynthesizing, SyntheticKeystrokePosting,
  @unchecked Sendable
{
  /// `XStringToKeysym` names for the physical modifier keys — outside the
  /// Latin-1 numeric-equals-codepoint trick `Latin1Keysym` uses for `v`, so
  /// these need a live-display lookup and are only ever resolved from this
  /// real, manual-verify-only type.
  private static let controlKeysymName = "Control_L"
  private static let shiftKeysymName = "Shift_L"
  private static let superKeysymName = "Super_L"

  private let display: OpaquePointer
  private let layoutResolver: any KeyboardLayoutResolving
  private let modifierWaiter: ModifierReleaseWaiter
  private let terminalIdentifier: @Sendable (FrontmostAppRef?) -> String?

  /// - Returns: `nil` on a Wayland session (see this type's doc comment)
  ///   or if `display` is `nil` (no X server reachable at all).
  public init?(
    display: OpaquePointer?,
    sessionType: SessionType,
    layoutResolver: any KeyboardLayoutResolving,
    modifierWaiter: ModifierReleaseWaiter,
    terminalIdentifier: @escaping @Sendable (FrontmostAppRef?) -> String? = { $0?.bundleID }
  ) {
    guard sessionType == .x11, let display else { return nil }
    self.display = display
    self.layoutResolver = layoutResolver
    self.modifierWaiter = modifierWaiter
    self.terminalIdentifier = terminalIdentifier
  }

  /// `app == nil` is unreachable in practice for this backend: `init?`
  /// above only ever succeeds on an X11 session, and `LinuxAppEnvironment`
  /// only sets `Paster.synthesizesWithoutVerifiedTarget` when the session
  /// is NOT X11 (see that property's doc comment) — so `Paster` never has a
  /// reason to call this with `nil` while an `XTestEventSynthesizer` is the
  /// active backend. Handled anyway, the same way `UInputEventSynthesizer`
  /// does, for type-safety and defense in depth rather than relying on that
  /// invariant holding forever.
  public func synthesizeCommandV(targeting app: FrontmostAppRef?) throws {
    let modifiers = TerminalAppRegistry.modifiers(forAppIdentifier: terminalIdentifier(app))
    guard post(KeyChord(modifiers: modifiers, character: "v")) else {
      throw PasteError.eventPostFailed
    }
  }

  @discardableResult
  public func post(_ chord: KeyChord) -> Bool {
    guard let resolved = layoutResolver.resolve(character: chord.character) else { return false }

    var modifierNames: [String] = []
    if chord.modifiers.contains(.control) { modifierNames.append(Self.controlKeysymName) }
    if chord.modifiers.contains(.superKey) { modifierNames.append(Self.superKeysymName) }
    if chord.modifiers.contains(.shift) || resolved.requiresShift {
      modifierNames.append(Self.shiftKeysymName)
    }

    var modifierKeycodes: [UInt8] = []
    for name in modifierNames {
      guard let keycode = keycode(forKeysymNamed: name) else { return false }
      modifierKeycodes.append(keycode)
    }

    // D16/D39 mitigation — see `UInputEventSynthesizer.post`'s matching
    // comment; XTEST-injected events are merged with physical modifier
    // state by the X server the same way uinput's are by the kernel.
    guard modifierWaiter.waitForRelease() == .released else { return false }

    let baseKeycode = UInt8(truncatingIfNeeded: resolved.x11Keycode)
    let pressed: Int32 = 1
    let released: Int32 = 0
    let noDelay: UInt = 0
    for keycode in modifierKeycodes {
      XTestFakeKeyEvent(display, UInt32(keycode), pressed, noDelay)
    }
    XTestFakeKeyEvent(display, UInt32(baseKeycode), pressed, noDelay)
    XTestFakeKeyEvent(display, UInt32(baseKeycode), released, noDelay)
    for keycode in modifierKeycodes.reversed() {
      XTestFakeKeyEvent(display, UInt32(keycode), released, noDelay)
    }
    XFlush(display)
    return true
  }

  private func keycode(forKeysymNamed name: String) -> UInt8? {
    let keysym = XStringToKeysym(name)
    guard keysym != 0 else { return nil }
    let keycode = XKeysymToKeycode(display, keysym)
    guard keycode != 0 else { return nil }
    return keycode
  }
}
