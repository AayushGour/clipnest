import ClipnestCore
import Foundation

/// `/dev/uinput`-backed `EventSynthesizing`/`SyntheticKeystrokePosting` —
/// the PREFERRED backend (see `LinuxEventSynthesizerSelection`): kernel-level
/// event injection works identically under X11 and Wayland, unlike XTEST.
///
/// Holds one `UInputDevice`, created ONCE by the composition root at
/// startup (see that type's doc comment) and injected here — this type
/// never creates or destroys the device itself.
public final class UInputEventSynthesizer: EventSynthesizing, SyntheticKeystrokePosting {
  private let device: UInputDevice
  private let layoutResolver: any KeyboardLayoutResolving
  private let modifierWaiter: ModifierReleaseWaiter
  private let terminalIdentifier: @Sendable (FrontmostAppRef?) -> String?

  public init(
    device: UInputDevice,
    layoutResolver: any KeyboardLayoutResolving,
    modifierWaiter: ModifierReleaseWaiter,
    terminalIdentifier: @escaping @Sendable (FrontmostAppRef?) -> String? = { $0?.bundleID }
  ) {
    self.device = device
    self.layoutResolver = layoutResolver
    self.modifierWaiter = modifierWaiter
    self.terminalIdentifier = terminalIdentifier
  }

  /// `app == nil` (T-WLPASTE-NIL1: `Paster.synthesizesWithoutVerifiedTarget`)
  /// means "post globally, no specific target to identify" — this device
  /// already posts through `/dev/uinput`'s kernel-level injection, which
  /// has no concept of a target process at all (unlike `CGEvent.postToPid`),
  /// so the ONLY thing `app` actually informs here is the terminal-modifier
  /// guess below. `terminalIdentifier(nil)`'s default (`{ $0?.bundleID }`)
  /// returns `nil`, and `TerminalAppRegistry.modifiers(forAppIdentifier:)`
  /// already defaults an unknown/`nil` identifier to plain Ctrl+V — the
  /// same "never assume a target is a terminal without a positive match"
  /// contract every other unrecognized app already gets, not a special case
  /// for the unverified-target path.
  public func synthesizeCommandV(targeting app: FrontmostAppRef?) throws {
    let modifiers = TerminalAppRegistry.modifiers(forAppIdentifier: terminalIdentifier(app))
    guard post(KeyChord(modifiers: modifiers, character: "v")) else {
      throw PasteError.eventPostFailed
    }
  }

  @discardableResult
  public func post(_ chord: KeyChord) -> Bool {
    guard let resolved = layoutResolver.resolve(character: chord.character) else { return false }
    let kernelKeycode = resolved.x11Keycode - InputConstants.x11KernelKeycodeOffset
    guard kernelKeycode >= 0, kernelKeycode <= Int32(LinuxEventCode.maxRegisteredKeycode) else {
      return false
    }
    let baseCode = UInt16(kernelKeycode)

    var modifierCodes: [UInt16] = []
    if chord.modifiers.contains(.control) { modifierCodes.append(LinuxEventCode.keyLeftCtrl) }
    if chord.modifiers.contains(.superKey) { modifierCodes.append(LinuxEventCode.keyLeftMeta) }
    if chord.modifiers.contains(.shift) || resolved.requiresShift {
      modifierCodes.append(LinuxEventCode.keyLeftShift)
    }

    // D16/D39 mitigation: never post with a physically-held modifier still
    // asserted (see `ModifierReleaseWaiter`'s doc comment) — the kernel
    // merges uinput's injected state with real physical state
    // unconditionally, unlike macOS's `.privateState` `CGEventSource`.
    guard modifierWaiter.waitForRelease() == .released else { return false }

    for code in modifierCodes {
      guard device.postKeyEvent(code: code, isPress: true) else { return false }
    }
    guard device.postKeyEvent(code: baseCode, isPress: true),
      device.postKeyEvent(code: baseCode, isPress: false)
    else { return false }
    for code in modifierCodes.reversed() {
      guard device.postKeyEvent(code: code, isPress: false) else { return false }
    }
    return true
  }
}
