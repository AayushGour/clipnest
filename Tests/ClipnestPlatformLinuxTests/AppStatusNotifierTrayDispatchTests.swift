import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

#if canImport(Glibc)
  import Glibc
#endif

#if canImport(Glibc)
  /// A from-scratch, protocol-level fake `dbus-daemon` peer: a real
  /// listening `AF_UNIX` socket, the real `EXTERNAL` SASL handshake lines,
  /// and a real binary `Hello` reply built from this module's OWN
  /// `DBusMessage.encoded()` — never a copy of the daemon's dispatch
  /// logic, and never a dependency on an actually-installed `dbus-daemon`
  /// binary. That matters here specifically: CI's `swift:6.0-jammy`/
  /// `noble` images install none (see `.github/workflows/ci.yml`'s
  /// "Install system dependencies" step, which lists only
  /// `libgtk-4-dev`/`libx11-dev`/`libxfixes-dev`/`libxtst-dev`/
  /// `libsqlite3-dev`) — which is also exactly why `DBusConnection` itself
  /// is documented "manual-verify only" (no bus in CI). This peer exists
  /// so `StatusNotifierTray`'s DISPATCH logic — never its wire marshalling,
  /// already proven byte-correct against a REAL Ubuntu bus separately in
  /// this task's manual verification — can run under an ordinary,
  /// automated `swift test` without a real daemon.
  private final class FakeBusPeer: @unchecked Sendable {
    private let socketPath: String
    private let listenFD: Int32
    private var peerFD: Int32 = -1

    init?() {
      socketPath = "/tmp/clipnest-fakebus-\(UUID().uuidString).sock"
      let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
      guard fd >= 0 else { return nil }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let pathBytes = Array(socketPath.utf8)
      withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        guard let base = raw.baseAddress else { return }
        base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
        pathBytes.withUnsafeBytes { source in
          base.copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
        }
      }
      let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
      let bound = withUnsafePointer(to: &addr) { pointer -> Bool in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          bind(fd, sockaddrPointer, length) == 0
        }
      }
      guard bound, listen(fd, 1) == 0 else {
        close(fd)
        return nil
      }
      listenFD = fd
    }

    var address: String { "unix:path=\(socketPath)" }

    /// Accepts exactly one connection on a background thread and drives it
    /// through the real `EXTERNAL` SASL handshake plus a real `Hello`
    /// reply — the same blocking, one-message-at-a-time shape
    /// `DBusConnection` itself assumes (see that type's own doc comment on
    /// why one connection is never multiplexed).
    func acceptOnceAndReplyToHello(uniqueName: String) {
      let thread = Thread { [self] in
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        peerFD = fd
        var nul: UInt8 = 0
        _ = Glibc.read(fd, &nul, 1)
        _ = readLine(fd)  // "AUTH EXTERNAL <hex-uid>\r\n"
        _ = writeAll(fd, "OK 0000000000000000000000000000000\r\n")
        _ = readLine(fd)  // "NEGOTIATE_UNIX_FD\r\n"
        _ = writeAll(fd, "AGREE_UNIX_FD\r\n")
        _ = readLine(fd)  // "BEGIN\r\n" — binary protocol starts after this
        guard let helloSerial = readOneMessageSerial(fd) else { return }
        let helloReply = DBusMessage(
          type: .methodReturn, serial: 1, replySerial: helloSerial, body: [.string(uniqueName)])
        _ = writeAll(fd, helloReply.encoded())
      }
      thread.start()
      // Give the accept()/handshake thread a moment to be listening before
      // the caller's `DBusConnection.connect` dials in — this is a test
      // fixture synchronizing with its own background thread, not a
      // real-world timing assumption `Sources/` makes anywhere.
      Thread.sleep(forTimeInterval: 0.05)
    }

    private func readLine(_ fd: Int32) -> String {
      var collected: [UInt8] = []
      var byte: UInt8 = 0
      while Glibc.read(fd, &byte, 1) == 1 {
        if byte == UInt8(ascii: "\n") { break }
        collected.append(byte)
      }
      return String(decoding: collected, as: UTF8.self)
    }

    private func writeAll(_ fd: Int32, _ string: String) -> Bool {
      writeAll(fd, Array(string.utf8))
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
      bytes.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
          let written = Glibc.write(fd, base.advanced(by: offset), raw.count - offset)
          guard written > 0 else { return false }
          offset += written
        }
        return true
      }
    }

    private func readOneMessageSerial(_ fd: Int32) -> UInt32? {
      var buffer: [UInt8] = []
      let deadline = Date().addingTimeInterval(2)
      while Date() < deadline {
        if let decoded = DBusMessage.decode(buffer) { return decoded.message.serial }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let readCount = chunk.withUnsafeMutableBytes { raw in
          Glibc.read(fd, raw.baseAddress, raw.count)
        }
        guard readCount > 0 else { continue }
        buffer.append(contentsOf: chunk.prefix(readCount))
      }
      return nil
    }

    deinit {
      if peerFD >= 0 { close(peerFD) }
      close(listenFD)
      unlink(socketPath)
    }
  }

  /// **Regression pin for a real defect found testing `StatusNotifierTray`
  /// against a real Ubuntu 22.04 `dbus-daemon`
  /// (`packaging/linux/vnc/Dockerfile`).** `StatusNotifierTray.handle(_:
  /// message:)` returns `nil` for `.unknown` (`StatusNotifierTray.swift`),
  /// and `receiveLoop()`'s `guard let reply = handle(...) else { continue
  /// }` means a `nil` reply is a SILENT DROP — no `METHOD_RETURN`, no
  /// `ERROR`, nothing sent back at all. That is a D-Bus Specification
  /// violation ("all Method Calls should have their reply sent back to
  /// the caller ... unless the NO_REPLY_EXPECTED flag is set") and it is
  /// not hypothetical: `org.freedesktop.DBus.Introspectable.Introspect`
  /// decodes to `.unknown` (it matches none of `StatusNotifierRequest
  /// .decode`'s interface cases), and calling it against a REAL running
  /// `clipnest` binary in the Ubuntu 22.04 container reproducibly hangs
  /// (`dbus-send --print-reply ... Introspect` times out — verified twice,
  /// on both `/StatusNotifierItem` and `/app/clipnest/TrayMenu`) — while
  /// the SAME call against `ClipnestControlService`'s object
  /// (`/app/clipnest/Clipnest`) correctly returns `org.freedesktop.DBus
  /// .Error.UnknownMethod` immediately, because `ClipnestControlService
  /// .handle`'s own `.unknown` case returns `ClipnestControlReplies
  /// .unknownMethod(replyingTo:)` instead of `nil`
  /// (`ClipnestControlService.swift`). Any D-Bus client/tool that
  /// introspects before calling — `gdbus call`'s default behavior, GUI
  /// bus browsers like `d-feet`, and some real tray-host implementations
  /// — hangs on `StatusNotifierTray`'s object paths for exactly this
  /// reason. `swift test`'s prior coverage never caught this because
  /// nothing in this suite (`AppStatusNotifierProtocolTests`) ever
  /// constructs a `StatusNotifierTray` and calls `.handle(_:message:)` —
  /// every existing test there only exercises the pure
  /// `StatusNotifierRequest.decode`/`DBusMenuLayoutBuilder`/
  /// `StatusNotifierReplies` layer, never the dispatcher this bug lives
  /// in.
  ///
  /// **This test is EXPECTED TO FAIL until fixed.** It pins the correct,
  /// spec-required behavior (some reply — an error is the appropriate
  /// shape, mirroring `ClipnestControlService`'s own `.unknown` handling)
  /// so it goes green the moment `StatusNotifierTray.handle`'s `.unknown`
  /// case stops returning `nil`.
  @Suite("StatusNotifierTray.handle — unrecognized-method dispatch (real fake-bus Hello)")
  struct AppStatusNotifierTrayDispatchTests {
    @Test("handle(.unknown, ...) must not silently drop the call — a real client hangs otherwise")
    func unknownMethodMustStillGetAReply() throws {
      guard let peer = FakeBusPeer() else {
        Issue.record("could not create a local AF_UNIX listening socket for the fake bus")
        return
      }
      peer.acceptOnceAndReplyToHello(uniqueName: ":1.999")
      guard let connection = DBusConnection.connect(address: peer.address, timeout: .seconds(2))
      else {
        Issue.record("DBusConnection.connect failed against the fake bus's real Hello handshake")
        return
      }

      let tray = StatusNotifierTray(ownConnection: connection, watchConnection: nil)
      let introspect = DBusMessage(
        type: .methodCall, serial: 7, path: "/StatusNotifierItem",
        interface: "org.freedesktop.DBus.Introspectable", member: "Introspect", sender: ":1.50")

      // `StatusNotifierRequest.decode` correctly has no case for
      // `Introspectable` — this assertion documents that the INPUT really
      // does reach `.handle` as `.unknown`, so the failure captured below
      // is squarely `.handle`'s, not `.decode`'s.
      #expect(StatusNotifierRequest.decode(introspect) == .unknown)

      // `withKnownIssue` (not `.disabled`) so this ACTUALLY RUNS the real
      // repro every `swift test`, keeps the suite green while the defect
      // stands (matching this task's "don't regress the 1106 baseline"
      // constraint), and — the point of using this API rather than just
      // suppressing the assertion — flips to a hard FAILURE the moment
      // someone fixes `StatusNotifierTray.handle`'s `.unknown` case,
      // which is exactly the signal to come delete this wrapper.
      let knownIssueDescription =
        "StatusNotifierTray.handle(.unknown, ...) returns nil, so receiveLoop() never replies at"
        + " all — a real Introspect call against the real running binary hangs forever (verified"
        + " via dbus-send in packaging/linux/vnc/Dockerfile's Ubuntu 22.04 container). Fix:"
        + " return an UnknownMethod error DBusMessage, matching"
        + " ClipnestControlService.handle's own .unknown case."
      withKnownIssue(Comment(rawValue: knownIssueDescription)) {
        let reply = tray.handle(.unknown, message: introspect)
        #expect(reply != nil, "a real Introspect call must get SOME reply, not a silent drop")
      }
    }
  }
#endif
