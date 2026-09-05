import Foundation

/// Central home for every magic number/string the Linux input-synthesis
/// stack (`Input/`) uses, per coding-standards.md's "no magic numbers"
/// rule — nothing below is duplicated inline anywhere else in this module.
public enum InputConstants {
  /// X11 keycodes are the kernel (evdev) keycode plus this fixed offset —
  /// a stable, documented X11 convention (the first 8 keycodes are
  /// reserved and unused by the X protocol). `X11KeyboardLayoutResolver`
  /// returns X11 keycodes; `UInputEventSynthesizer` subtracts this before
  /// writing to `/dev/uinput`, which speaks kernel keycodes.
  public static let x11KernelKeycodeOffset: Int32 = 8

  /// How often `ModifierReleaseWaiter` polls the live modifier mask while
  /// waiting for the user to physically release the hotkey's modifiers.
  public static let modifierPollInterval: Duration = .milliseconds(10)

  /// The longest `ModifierReleaseWaiter` will wait before giving up and
  /// reporting a typed failure rather than risk sending a paste chord with
  /// stale modifiers still asserted (the D16/D39 bug class — worse on
  /// Linux than macOS because uinput/XTEST-injected events are merged with
  /// PHYSICAL key state unconditionally by the kernel).
  public static let modifierReleaseCeiling: Duration = .milliseconds(400)

  /// After `UI_DEV_CREATE`, udev/libinput need a moment to enumerate the
  /// new virtual device before it reliably delivers its first keystrokes. A
  /// create-per-paste device silently drops early events without this.
  public static let uinputDeviceSettleDelay: Duration = .milliseconds(400)

  /// The `/dev/uinput` device name `UInputDevice.open` registers via
  /// `UI_DEV_SETUP`.
  public static let uinputDeviceName = "Clipnest Virtual Keyboard"
}
