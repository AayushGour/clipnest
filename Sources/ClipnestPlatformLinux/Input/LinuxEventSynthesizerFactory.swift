import CXlib
import ClipnestCore
import Foundation

/// Builds the real, priority-ordered `EventSynthesizing` for this process:
/// uinput if `/dev/uinput` is writable, else XTEST on an X11 session, else
/// the clipboard-only fallback. Call ONCE at app startup, off the main
/// thread — `UInputDevice.open` blocks for
/// `InputConstants.uinputDeviceSettleDelay` (400ms) when uinput IS
/// available, and opening an X11 `Display` is itself a blocking round
/// trip.
///
/// Manual-verify only, by construction — it can only be exercised against
/// a real `/dev/uinput`/X server, neither of which exist in the CI
/// container this ships to. `LinuxEventSynthesizerSelection.choose` (the
/// decision this wraps) is unit-tested directly instead.
public enum LinuxEventSynthesizerFactory {
  public static func makeDefault(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> (synthesizer: any EventSynthesizing, kind: SelectedEventSynthesizerKind) {
    let sessionType = SessionType.detect(environment: environment)

    if let device = UInputDevice.open() {
      let display = XOpenDisplay(nil)
      let layoutResolver = X11KeyboardLayoutResolver(display: display)
      // T-MODWAIT-WAYLAND1: `XQueryPointer` only reflects true physical
      // modifier state on a real X11 session — under Wayland (XWayland
      // reachable or not) it reports an empty mask while modifiers are
      // physically held whenever a native-Wayland window has focus, so
      // `WaitForReleaseModifierGuard` would be inert there. Branch on
      // `sessionType`, not display reachability, per that finding.
      let modifierGuard: any ModifierGuarding
      switch sessionType {
      case .x11:
        let reader: any ModifierMaskReading =
          display.map { X11ModifierMaskReader(display: $0) } ?? NullModifierMaskReader()
        modifierGuard = WaitForReleaseModifierGuard(waiter: ModifierReleaseWaiter(reader: reader))
      case .wayland, .unknown:
        modifierGuard = ForceReleaseModifierGuard(device: device)
      }
      return (
        UInputEventSynthesizer(
          device: device, layoutResolver: layoutResolver, modifierGuard: modifierGuard),
        .uinput
      )
    }

    if sessionType == .x11, let display = XOpenDisplay(nil) {
      let layoutResolver = X11KeyboardLayoutResolver(display: display)
      let modifierWaiter = ModifierReleaseWaiter(reader: X11ModifierMaskReader(display: display))
      if let xtest = XTestEventSynthesizer(
        display: display, sessionType: sessionType, layoutResolver: layoutResolver,
        modifierWaiter: modifierWaiter)
      {
        return (xtest, .xtest)
      }
    }

    return (NullClipboardOnlyEventSynthesizer(), .clipboardOnly)
  }
}
