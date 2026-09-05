import Foundation

/// Pure byte-level encoders for the two `/dev/uinput` wire structures this
/// module writes — `struct input_event` (one key transition) and
/// `struct uinput_setup` (device registration). Kept separate from
/// `UInputDevice` (the real file-descriptor/ioctl side) so the actual byte
/// layout is unit-testable without `/dev/uinput` — there is none in the CI
/// container this ships to.
///
/// Layout assumptions (fixed by the Linux kernel ABI on the only target
/// this module ships to — x86_64 Ubuntu 22.04/24.04 desktop):
/// `struct input_event { struct timeval time; __u16 type; __u16 code;
/// __s32 value; }`, with `struct timeval` using 64-bit `time_t`/
/// `suseconds_t` on this platform (16 bytes total), so the whole struct is
/// 24 bytes with no implicit padding. The injected timestamp is always
/// zero — the kernel fills in the real one; userspace's `time` field is
/// documented as ignored for events written INTO `/dev/uinput`.
public enum UInputEventEncoding {
  /// Total encoded size of one `struct input_event` on this platform.
  public static let inputEventByteCount = 24

  /// `struct uinput_setup`'s fixed device-name buffer size
  /// (`UINPUT_MAX_NAME_SIZE`).
  public static let maxDeviceNameByteCount = 80

  /// Encodes one `struct input_event { time = {0,0}; type; code; value }`,
  /// little-endian (the only byte order any of this module's targets run).
  public static func encodeInputEvent(type: UInt16, code: UInt16, value: Int32) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(inputEventByteCount)
    bytes.append(contentsOf: repeatElement(0, count: 16))  // tv_sec + tv_usec, both zero
    bytes.append(contentsOf: littleEndianBytes(of: type))
    bytes.append(contentsOf: littleEndianBytes(of: code))
    bytes.append(contentsOf: littleEndianBytes(of: UInt32(bitPattern: value)))
    return bytes
  }

  /// Encodes `struct uinput_setup { struct input_id id; char name[80];
  /// __u32 ff_effects_max; }`, where `struct input_id` is four `__u16`s:
  /// `bustype, vendor, product, version`.
  ///
  /// - Parameter name: the device name (`InputConstants.uinputDeviceName`);
  ///   truncated (never crashes) if somehow longer than
  ///   `maxDeviceNameByteCount - 1` UTF-8 bytes (room for the NUL
  ///   terminator) — always false for the one literal this module ever
  ///   passes, but this is a pure function and should not trap on a
  ///   hypothetical long input.
  public static func encodeDeviceSetup(
    busType: UInt16, vendor: UInt16, product: UInt16, version: UInt16, name: String,
    ffEffectsMax: UInt32
  ) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.append(contentsOf: littleEndianBytes(of: busType))
    bytes.append(contentsOf: littleEndianBytes(of: vendor))
    bytes.append(contentsOf: littleEndianBytes(of: product))
    bytes.append(contentsOf: littleEndianBytes(of: version))

    var nameBytes = Array(name.utf8.prefix(maxDeviceNameByteCount - 1))
    nameBytes.append(
      contentsOf: repeatElement(0, count: maxDeviceNameByteCount - nameBytes.count))
    bytes.append(contentsOf: nameBytes)

    bytes.append(contentsOf: littleEndianBytes(of: ffEffectsMax))
    return bytes
  }

  private static func littleEndianBytes(of value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
  }

  private static func littleEndianBytes(of value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
  }
}
