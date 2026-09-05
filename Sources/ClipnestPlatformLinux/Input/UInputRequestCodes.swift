import Foundation

/// The `/dev/uinput` ioctl requests this module issues.
/// `UINPUT_IOCTL_BASE` ('U') and the request numbers below are part of the
/// stable Linux kernel UAPI (`linux/uinput.h`) and have not changed since
/// uinput's inception. They're hand-transcribed here (rather than imported
/// from a C module) because `CXlib` only exposes Xlib/XTest/Xfixes headers
/// — see `Package.swift`'s Linux target graph, which this module does not
/// modify. `IOCtlRequestCode` reconstructs the actual ioctl numbers from
/// the same formula the kernel headers use, so only the base/number/size
/// inputs below need to be trusted against the kernel source, not an
/// opaque final integer.
public enum UInputRequestCodes {
  private static let ioctlBase: UInt8 = 0x55  // 'U'

  public static let devCreate = IOCtlRequestCode.io(type: ioctlBase, number: 1)
  public static let devDestroy = IOCtlRequestCode.io(type: ioctlBase, number: 2)
  public static let devSetup = IOCtlRequestCode.iow(
    type: ioctlBase, number: 3, size: UInputDeviceSetupLayout.byteCount)
  public static let setEvBit = IOCtlRequestCode.iow(type: ioctlBase, number: 100, size: 4)
  public static let setKeyBit = IOCtlRequestCode.iow(type: ioctlBase, number: 101, size: 4)
}

/// `struct uinput_setup`'s total byte size — kept beside
/// `UInputEventEncoding.encodeDeviceSetup` so the ioctl's declared payload
/// size and the actual encoded buffer size can never drift apart.
public enum UInputDeviceSetupLayout {
  /// 4×`__u16` (`struct input_id`) + 80-byte name + `__u32` (`ff_effects_max`).
  public static let byteCount = 4 * 2 + UInputEventEncoding.maxDeviceNameByteCount + 4
}

/// Linux event-type and modifier/base keycodes this module ever emits —
/// `linux/input-event-codes.h`'s stable numbering.
public enum LinuxEventCode {
  public static let evSyn: UInt16 = 0x00
  public static let evKey: UInt16 = 0x01
  public static let synReport: UInt16 = 0
  public static let keyLeftCtrl: UInt16 = 29
  public static let keyLeftShift: UInt16 = 42
  public static let keyLeftMeta: UInt16 = 125  // Super/Windows key
  /// Highest kernel keycode this device registers via `UI_SET_KEYBIT` at
  /// setup — covers every standard key (letters, digits, punctuation,
  /// modifiers, function keys). The exact keycode sent for the base
  /// character key is resolved dynamically per the active layout
  /// (`KeyboardLayoutResolving`), so the full range must be pre-registered
  /// before `UI_DEV_CREATE`: uinput refuses to emit an unregistered keycode
  /// later.
  public static let maxRegisteredKeycode: UInt16 = 255
}

/// `linux/input.h`'s `BUS_VIRTUAL` — the one bus-type value this module
/// needs, so `UInputDevice.open` doesn't hardcode it inline.
public enum BusType {
  public static let virtual: UInt16 = 0x06
}
