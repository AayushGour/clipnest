import Foundation

#if canImport(Glibc)
  import Glibc
#endif

/// Errors specific to standing up the `/dev/uinput` virtual keyboard.
public enum UInputError: Error, Equatable, Sendable {
  case deviceUnavailable
  case setupFailed
}

#if canImport(Glibc)
  // glibc declares `ioctl` as a bare C variadic function
  // (`int ioctl(int, unsigned long, ...)`) with no `printf`-style format
  // attribute, so the ClangImporter refuses to bridge it to a callable
  // `CVarArg...` overload — calling `Glibc.ioctl` directly fails to compile
  // with "'ioctl' is unavailable: Variadic function is unavailable."
  //
  // The fix is to resolve `ioctl`'s address ourselves via `dlsym` (against
  // the running process's OWN symbol table — `dlopen(nil, ...)` never
  // actually loads a new shared object, since libc is already linked into
  // every Swift-on-Linux binary) and reinterpret it as whichever
  // FIXED-arity C function-pointer shape a given call site needs. This is
  // ABI-correct: at the SysV calling convention this module ships on
  // (x86_64/arm64 Ubuntu), a variadic function invoked with exactly one
  // trailing scalar or pointer argument uses the identical
  // register-passing convention as an equivalent fixed-arity function
  // declared with that same parameter list.
  //
  // (An earlier attempt bound three `@_silgen_name("ioctl")` Swift
  // declarations, one per shape, directly to the symbol — that FAILED to
  // compile: the compiler interns `@_silgen_name` thin-function references
  // by symbol name, so the three different declared Swift signatures
  // collided into "function type mismatch" errors at every call site but
  // the first. Resolving the address once via `dlsym` and reinterpreting
  // it per call site with `unsafeBitCast` — the language's sanctioned
  // mechanism for exactly this "I know the true C signature of this
  // pointer" situation, with no safer alternative — avoids that collision
  // entirely.)
  private enum RawIoctl {
    private typealias IntArgFunction = @convention(c) (Int32, UInt, Int32) -> Int32
    private typealias PointerArgFunction =
      @convention(c) (Int32, UInt, UnsafeRawPointer?) ->
      Int32
    private typealias NoArgFunction = @convention(c) (Int32, UInt) -> Int32

    // `nonisolated(unsafe)`: `UnsafeMutableRawPointer` isn't `Sendable` (a
    // raw pointer could reference shared mutable state in general), but
    // this one specific pointer is the process-lifetime, immutable-after-
    // initialization address of libc's `ioctl` function itself — resolved
    // exactly once via `static let`'s thread-safe lazy-initialization
    // guarantee, then only ever read, never written, from any thread.
    nonisolated(unsafe) private static let symbol: UnsafeMutableRawPointer? = {
      guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
      return dlsym(handle, "ioctl")
    }()

    static func call(_ fd: Int32, _ request: UInt, intArgument: Int32) -> Int32 {
      guard let symbol else { return -1 }
      return unsafeBitCast(symbol, to: IntArgFunction.self)(fd, request, intArgument)
    }

    static func call(_ fd: Int32, _ request: UInt, pointerArgument: UnsafeRawPointer?) -> Int32 {
      guard let symbol else { return -1 }
      return unsafeBitCast(symbol, to: PointerArgFunction.self)(fd, request, pointerArgument)
    }

    static func call(_ fd: Int32, _ request: UInt) -> Int32 {
      guard let symbol else { return -1 }
      return unsafeBitCast(symbol, to: NoArgFunction.self)(fd, request)
    }
  }
#endif

/// Owns ONE `/dev/uinput` virtual keyboard file descriptor for the whole
/// process lifetime. Manual-verify only: there is no `/dev/uinput` in the
/// CI container this ships to, so nothing here is exercised by
/// `swift test` — only `UInputEventEncoding`/`IOCtlRequestCode` (the pure
/// byte/number logic this type calls into) are unit-tested.
///
/// **Must be created exactly once, off the caller's hot path**: the 400ms
/// settle sleep after `UI_DEV_CREATE`
/// (`InputConstants.uinputDeviceSettleDelay` — udev/libinput need that long
/// to enumerate the new device before it reliably delivers keystrokes)
/// makes `open()` unsuitable to call per-paste. The Linux composition root
/// (out of this module's scope) is responsible for calling `open()` once
/// at app startup, off the main thread — this type itself has no
/// threading opinion beyond "don't call this twice."
public final class UInputDevice: Sendable {
  private let fileDescriptor: Int32

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  /// Opens `/dev/uinput`, registers `EV_KEY` plus every keycode in
  /// `0...LinuxEventCode.maxRegisteredKeycode`, calls `UI_DEV_SETUP` +
  /// `UI_DEV_CREATE`, then blocks for
  /// `InputConstants.uinputDeviceSettleDelay` before returning — see this
  /// type's doc comment for why that sleep is unavoidable here rather than
  /// deferred.
  ///
  /// - Returns: `nil` if `/dev/uinput` doesn't exist or isn't writable by
  ///   this user (the common case: the `uinput` group/udev rule isn't set
  ///   up) — callers treat that as "uinput unavailable," falling through to
  ///   XTEST or the null backend (`LinuxEventSynthesizerSelection`).
  public static func open(devicePath: String = "/dev/uinput") -> UInputDevice? {
    #if canImport(Glibc)
      let fd = devicePath.withCString { Glibc.open($0, O_WRONLY | O_NONBLOCK) }
      guard fd >= 0 else { return nil }

      guard
        RawIoctl.call(fd, UInputRequestCodes.setEvBit, intArgument: Int32(LinuxEventCode.evKey))
          == 0
      else {
        Glibc.close(fd)
        return nil
      }
      for keycode in 0...Int32(LinuxEventCode.maxRegisteredKeycode) {
        guard RawIoctl.call(fd, UInputRequestCodes.setKeyBit, intArgument: keycode) == 0 else {
          Glibc.close(fd)
          return nil
        }
      }

      let setupBytes = UInputEventEncoding.encodeDeviceSetup(
        busType: BusType.virtual, vendor: 0, product: 0, version: 1,
        name: InputConstants.uinputDeviceName, ffEffectsMax: 0)
      let setupSucceeded = setupBytes.withUnsafeBytes { rawBuffer -> Bool in
        RawIoctl.call(fd, UInputRequestCodes.devSetup, pointerArgument: rawBuffer.baseAddress)
          == 0
      }
      guard setupSucceeded, RawIoctl.call(fd, UInputRequestCodes.devCreate) == 0 else {
        Glibc.close(fd)
        return nil
      }

      BlockingSleep.sleep(InputConstants.uinputDeviceSettleDelay)
      return UInputDevice(fileDescriptor: fd)
    #else
      return nil
    #endif
  }

  /// Writes one key transition plus its `EV_SYN`/`SYN_REPORT` — every
  /// write to `/dev/uinput` must be followed by a sync report or the
  /// compositor never sees the event as "complete."
  @discardableResult
  public func postKeyEvent(code: UInt16, isPress: Bool) -> Bool {
    #if canImport(Glibc)
      let keyEvent = UInputEventEncoding.encodeInputEvent(
        type: LinuxEventCode.evKey, code: code, value: isPress ? 1 : 0)
      let syncEvent = UInputEventEncoding.encodeInputEvent(
        type: LinuxEventCode.evSyn, code: LinuxEventCode.synReport, value: 0)
      return writeRaw(keyEvent) && writeRaw(syncEvent)
    #else
      return false
    #endif
  }

  #if canImport(Glibc)
    private func writeRaw(_ bytes: [UInt8]) -> Bool {
      bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return false }
        return Glibc.write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
      }
    }
  #endif

  deinit {
    #if canImport(Glibc)
      _ = RawIoctl.call(fileDescriptor, UInputRequestCodes.devDestroy)
      Glibc.close(fileDescriptor)
    #endif
  }
}
