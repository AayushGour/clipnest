import ClipnestPlatformLinux
import Foundation

/// Sends a `DBusMessage` and returns its matching reply, or `nil` on any
/// error/timeout. The seam every D-Bus-driven type in this module (the
/// control service, the single-instance forwarder, the Shell-extension
/// client, the tray) calls through instead of a concrete `DBusConnection`
/// directly, so their request-building/response-handling logic is
/// unit-testable with a fake that returns canned replies — no real session
/// bus needed (see this task's "no real bus in tests" constraint).
///
/// Deliberately a NEW, small protocol rather than reusing
/// `ClipnestPlatformLinux.ATSPIObjectCalling` (which has the identical
/// shape): that protocol's name specifically documents the accessibility
/// bus, and this module's calls are all against the SESSION bus — reusing
/// it here would be a misleading name, not a saved abstraction.
/// `DBusConnection` (the one real D-Bus implementation this whole app
/// uses — see this task's directive: reuse it, never write a second one)
/// already satisfies this shape by construction, so
/// `extension DBusConnection: DBusCalling {}` below needs no new code.
public protocol DBusCalling: Sendable {
  func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage?

  /// Same contract as `call(_:timeout:)`, for a request/reply pair that
  /// attaches real UNIX file descriptors — `app.clipnest.ShellHelper1`'s
  /// five clipboard-payload members (`ReadClipboard`/`SetClipboard`/
  /// `GetClipboardMimeTypes`/`SetClipboardWatch`/`ClipboardChanged`, see
  /// `ShellHelperClient`) are the only callers of this today. Every
  /// returned descriptor in `fileDescriptors` is CALLER-OWNED from this
  /// point — see `ClipnestPlatformLinux.DBusConnection
  /// .receiveOneMessageWithFileDescriptors(timeout:)`'s contract, which
  /// `DBusConnection`'s own conformance (below) delegates to.
  func call(
    _ message: DBusMessage, attachingFileDescriptors: [Int32], timeout: Duration
  ) -> (message: DBusMessage, fileDescriptors: [Int32])?
}

extension DBusCalling {
  /// Default: "unsupported" — every conformer that predates fd support
  /// (`FakeDBusCalling` in tests, and any future non-fd-capable calling
  /// seam) needs no change. `DBusConnection` is the only conformer that
  /// overrides this, with the real `sendmsg`/`recvmsg`+`SCM_RIGHTS`
  /// implementation.
  public func call(
    _ message: DBusMessage, attachingFileDescriptors: [Int32], timeout: Duration
  ) -> (message: DBusMessage, fileDescriptors: [Int32])? {
    nil
  }
}

extension DBusConnection: DBusCalling {}
