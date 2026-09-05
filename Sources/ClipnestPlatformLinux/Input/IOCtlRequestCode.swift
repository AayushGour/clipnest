import Foundation

/// Reimplements the Linux kernel's `_IO`/`_IOW` ioctl-request-code macros
/// (`include/uapi/asm-generic/ioctl.h` — stable and unchanged for decades)
/// rather than hardcoding the resulting numbers, so a reviewer can check
/// this against the kernel header formula directly instead of trusting an
/// opaque hex literal (coding-standards.md's "no magic numbers" — the
/// formula itself is the documentation). Used only for the handful of
/// `/dev/uinput` ioctls this module issues (`UInputDevice`).
public enum IOCtlRequestCode {
  private static let directionNone: UInt = 0
  private static let directionWrite: UInt = 1
  private static let directionShift: UInt = 30
  private static let sizeShift: UInt = 16
  private static let typeShift: UInt = 8

  private static func encode(direction: UInt, type: UInt8, number: UInt8, size: Int) -> UInt {
    (direction << directionShift) | (UInt(size) << sizeShift) | (UInt(type) << typeShift)
      | UInt(number)
  }

  /// `_IO(type, number)` — no argument payload (`UI_DEV_CREATE`,
  /// `UI_DEV_DESTROY`).
  public static func io(type: UInt8, number: UInt8) -> UInt {
    encode(direction: directionNone, type: type, number: number, size: 0)
  }

  /// `_IOW(type, number, size)` — writes `size` bytes of argument
  /// (`UI_DEV_SETUP`, `UI_SET_EVBIT`, `UI_SET_KEYBIT`).
  public static func iow(type: UInt8, number: UInt8, size: Int) -> UInt {
    encode(direction: directionWrite, type: type, number: number, size: size)
  }
}
