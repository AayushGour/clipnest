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

  /// **T-WB2 — FIXED, regression-pinned.** `StatusNotifierTray.handle(_:
  /// message:)` used to return `nil` for `.unknown` (`StatusNotifierTray
  /// .swift`), and `receiveLoop()`'s `guard let reply = handle(...) else {
  /// continue }` turned a `nil` reply into a SILENT DROP — no
  /// `METHOD_RETURN`, no `ERROR`, nothing sent back at all. That was a
  /// D-Bus Specification violation ("all Method Calls should have their
  /// reply sent back to the caller ... unless the NO_REPLY_EXPECTED flag is
  /// set") and it was not hypothetical:
  /// `org.freedesktop.DBus.Introspectable.Introspect` used to decode to
  /// `.unknown` (it matched none of `StatusNotifierRequest.decode`'s
  /// interface cases), and calling it against a REAL running `clipnest`
  /// binary in the Ubuntu 22.04 container reproducibly hung (`dbus-send
  /// --print-reply ... Introspect` timed out — verified twice, on both
  /// `/StatusNotifierItem` and `/app/clipnest/TrayMenu`) — while the SAME
  /// call against `ClipnestControlService`'s object
  /// (`/app/clipnest/Clipnest`) correctly returned `org.freedesktop.DBus
  /// .Error.UnknownMethod` immediately, because `ClipnestControlService
  /// .handle`'s own `.unknown` case returns `ClipnestControlReplies
  /// .unknownMethod(replyingTo:)` instead of `nil`
  /// (`ClipnestControlProtocol.swift`). Any D-Bus client/tool that
  /// introspects before calling — `gdbus call`'s default behavior, GUI bus
  /// browsers like `d-feet`, and some real tray-host implementations —
  /// hung on `StatusNotifierTray`'s object paths for exactly this reason.
  /// `swift test`'s prior coverage never caught this because nothing in
  /// `AppStatusNotifierProtocolTests` ever constructs a `StatusNotifierTray`
  /// and calls `.handle(_:message:)` — every existing test there only
  /// exercises the pure `StatusNotifierRequest.decode`/
  /// `DBusMenuLayoutBuilder`/`StatusNotifierReplies` layer, never the
  /// dispatcher this bug lived in.
  ///
  /// **Fix, two parts (`StatusNotifierProtocol.swift`/`StatusNotifierTray
  /// .swift`/`StatusNotifierIntrospection.swift`):**
  /// 1. `Introspect` now decodes to its own `.introspect(path:)` case and
  ///    gets a REAL introspection-XML reply describing whichever object
  ///    path was actually queried (`StatusNotifierIntrospection.xml
  ///    (forPath:)`) — "every object we export must answer
  ///    `Introspectable.Introspect`", not merely fail fast.
  /// 2. Every OTHER genuinely unrecognized method now maps to `.unknown`,
  ///    and `StatusNotifierTray.handle`'s `.unknown` case returns
  ///    `StatusNotifierReplies.unknownMethod(replyingTo:)` — a proper
  ///    `org.freedesktop.DBus.Error.UnknownMethod` — instead of `nil`.
  ///    `handle`'s return type is now the NON-optional `DBusMessage` (was
  ///    `DBusMessage?`), so a future silent-drop regression is a compile
  ///    error, not a runtime hang.
  @Suite("StatusNotifierTray.handle — unrecognized-method dispatch (real fake-bus Hello)")
  struct AppStatusNotifierTrayDispatchTests {
    private func connectedTray() throws -> (tray: StatusNotifierTray, peer: FakeBusPeer) {
      guard let peer = FakeBusPeer() else {
        Issue.record("could not create a local AF_UNIX listening socket for the fake bus")
        throw TestSetupFailure.fakeBusUnavailable
      }
      peer.acceptOnceAndReplyToHello(uniqueName: ":1.999")
      guard let connection = DBusConnection.connect(address: peer.address, timeout: .seconds(2))
      else {
        Issue.record("DBusConnection.connect failed against the fake bus's real Hello handshake")
        throw TestSetupFailure.connectFailed
      }
      return (StatusNotifierTray(ownConnection: connection, watchConnection: nil), peer)
    }

    @Test("Introspect on /StatusNotifierItem decodes to .introspect, not .unknown, and replies")
    func introspectOnItemPathGetsARealReply() throws {
      let (tray, _) = try connectedTray()
      let introspect = DBusMessage(
        type: .methodCall, serial: 7, path: StatusNotifierItemName.objectPath,
        interface: "org.freedesktop.DBus.Introspectable", member: "Introspect", sender: ":1.50")

      let decoded = StatusNotifierRequest.decode(introspect)
      #expect(decoded == .introspect(path: StatusNotifierItemName.objectPath))

      let reply = tray.handle(decoded!, message: introspect)
      #expect(reply.type == .methodReturn)
      #expect(reply.replySerial == 7)
      guard case .string(let xml)? = reply.body.first else {
        Issue.record("expected Introspect's reply body to be a single string")
        return
      }
      // The real defect: a real Introspect call must describe the REAL
      // interface at this path, not just avoid hanging.
      #expect(xml.contains(StatusNotifierItemName.interface))
      #expect(xml.contains(StatusNotifierItemMember.activate))
      #expect(xml.contains(FreedesktopIntrospectableName.interface))
    }

    @Test("Introspect on /app/clipnest/TrayMenu describes com.canonical.dbusmenu")
    func introspectOnMenuPathDescribesDBusMenu() throws {
      let (tray, _) = try connectedTray()
      let introspect = DBusMessage(
        type: .methodCall, serial: 8, path: DBusMenuName.objectPath,
        interface: "org.freedesktop.DBus.Introspectable", member: "Introspect", sender: ":1.50")

      let decoded = StatusNotifierRequest.decode(introspect)
      #expect(decoded == .introspect(path: DBusMenuName.objectPath))

      let reply = tray.handle(decoded!, message: introspect)
      #expect(reply.type == .methodReturn)
      guard case .string(let xml)? = reply.body.first else {
        Issue.record("expected Introspect's reply body to be a single string")
        return
      }
      #expect(xml.contains(DBusMenuName.interface))
      #expect(xml.contains(DBusMenuMember.getLayout))
      #expect(xml.contains(DBusMenuMember.getGroupProperties))
    }

    @Test("handle(.unknown, ...) must not silently drop the call — a real client hung otherwise")
    func unknownMethodGetsAProperErrorReply() throws {
      let (tray, _) = try connectedTray()
      let bogus = DBusMessage(
        type: .methodCall, serial: 9, path: StatusNotifierItemName.objectPath,
        interface: "com.example.NotARealInterface", member: "NotARealMethod", sender: ":1.50")

      #expect(StatusNotifierRequest.decode(bogus) == .unknown)

      let reply = tray.handle(.unknown, message: bogus)
      #expect(reply.type == .error, "a real unrecognized call must get an ERROR, not a silent drop")
      #expect(reply.errorName == StatusNotifierErrorName.unknownMethod)
      #expect(reply.replySerial == 9)
    }
  }

  private enum TestSetupFailure: Error {
    case fakeBusUnavailable
    case connectFailed
  }
#endif
