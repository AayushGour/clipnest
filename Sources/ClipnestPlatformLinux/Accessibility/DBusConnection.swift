import Foundation
import Synchronization

#if canImport(Glibc)
  import Glibc
#endif

/// A real, blocking `AF_UNIX` D-Bus connection: connects, performs the
/// `EXTERNAL` SASL handshake (`DBusAuthHandshake`), then sends/receives
/// binary `DBusMessage`s.
///
/// **Manual-verify only** — there is no D-Bus daemon reachable in the CI
/// container this ships to (no session bus, no a11y bus), so nothing in
/// this file is exercised by `swift test`. Every collaborator it's built
/// from that IS pure (`DBusAddress`, `DBusAuthHandshake`,
/// `DBusMessage.encoded()`/`.decode(_:)`) is unit-tested directly instead.
///
/// **Design simplification, stated explicitly:** this module uses a
/// SEPARATE `DBusConnection` for the AT-SPI focus-tracking signal stream
/// (`ATSPIFocusTracker`) than for on-demand `Text`/`EditableText` calls
/// (`ATSPITextAccessor`), even though both talk to the same a11y bus. A
/// single shared connection would need a demultiplexer distinguishing
/// unsolicited signals from a specific in-flight call's reply, running on
/// its own background reader thread. Two independent connections avoid
/// that entirely: the focus-tracking connection only ever reads signals in
/// a simple loop; the call connection only ever does one strict
/// send-then-block-for-this-reply cycle at a time. Two connections to the
/// same bus from one process is normal, fully-supported D-Bus usage.
public final class DBusConnection: @unchecked Sendable {
  private let fileDescriptor: Int32
  private let state = Mutex<State>(State())

  private struct State {
    var nextSerial: UInt32 = 1
    var receiveBuffer: [UInt8] = []
  }

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  deinit {
    #if canImport(Glibc)
      Glibc.close(fileDescriptor)
    #endif
  }

  /// Connects to `address` (a D-Bus server address string — see
  /// `DBusAddress`), performs the `EXTERNAL` auth handshake, and returns a
  /// ready-to-use connection, or `nil` on any failure (unreachable socket,
  /// auth rejected, malformed address).
  public static func connect(address: String, timeout: Duration) -> DBusConnection? {
    #if canImport(Glibc)
      guard let target = DBusAddress.parseFirstUnixTarget(address) else { return nil }
      guard let fd = openUnixSocket(target: target, timeout: timeout) else { return nil }
      let connection = DBusConnection(fileDescriptor: fd)
      guard connection.performExternalAuth() else {
        Glibc.close(fd)
        return nil
      }
      return connection
    #else
      return nil
    #endif
  }

  /// Next outgoing message serial for THIS connection — D-Bus requires
  /// serials be non-zero and unique per connection, not globally.
  public func allocateSerial() -> UInt32 {
    state.withLock { state in
      defer { state.nextSerial += 1 }
      return state.nextSerial
    }
  }

  #if canImport(Glibc)
    private static func openUnixSocket(target: DBusSocketTarget, timeout: Duration) -> Int32? {
      let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
      guard fd >= 0 else { return nil }
      applyTimeout(timeout, toFileDescriptor: fd)

      let connected = withSockaddrUn(target: target) { sockaddrPointer, length in
        Glibc.connect(fd, sockaddrPointer, length) == 0
      }
      guard connected == true else {
        Glibc.close(fd)
        return nil
      }
      return fd
    }

    private static func applyTimeout(_ duration: Duration, toFileDescriptor fd: Int32) {
      var tv = timeval()
      // `.init(...)` rather than a direct assignment: `timeval.tv_sec`/
      // `.tv_usec`'s exact imported integer type (`Int` vs `Int32`, per the
      // platform's `time_t`/`suseconds_t` width) isn't something this file
      // hardcodes an assumption about — `BinaryInteger.init(_:)` converts
      // from `Duration.components`' `Int64` fields to whatever that type
      // actually is.
      tv.tv_sec = .init(duration.components.seconds)
      tv.tv_usec = .init(duration.components.attoseconds / 1_000_000_000_000)
      withUnsafeBytes(of: &tv) { rawBuffer in
        _ = Glibc.setsockopt(
          fd, SOL_SOCKET, SO_RCVTIMEO, rawBuffer.baseAddress, socklen_t(rawBuffer.count))
      }
    }

    /// Builds a `sockaddr_un` for `target` and hands a `sockaddr*` view of
    /// it (plus the correct address length — abstract-socket names are NOT
    /// NUL-terminated on the wire, so the length must be computed from the
    /// name's byte count, not `strlen`) to `body`.
    private static func withSockaddrUn<T>(
      target: DBusSocketTarget, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T? {
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)

      let pathBytes: [UInt8]
      switch target {
      case .path(let path):
        pathBytes = Array(path.utf8)
      case .abstract(let name):
        // Leading NUL marks the Linux abstract-socket namespace.
        pathBytes = [0] + Array(name.utf8)
      }
      let capacity = MemoryLayout.size(ofValue: addr.sun_path)
      guard pathBytes.count <= capacity else { return nil }

      withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        base.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        pathBytes.withUnsafeBytes { sourceBuffer in
          guard let sourceBase = sourceBuffer.baseAddress else { return }
          base.copyMemory(from: sourceBase, byteCount: pathBytes.count)
        }
      }

      let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
      return withUnsafePointer(to: &addr) { rawAddress in
        rawAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          body(sockaddrPointer, addressLength)
        }
      }
    }

    private func performExternalAuth() -> Bool {
      let uid = Glibc.getuid()
      var handshakeBytes: [UInt8] = [DBusAuthHandshake.initialNulByte]
      handshakeBytes.append(contentsOf: Array(DBusAuthHandshake.externalAuthLine(uid: uid).utf8))
      guard writeRaw(handshakeBytes) else { return false }

      guard let responseLine = readLine(timeout: .seconds(1)) else { return false }
      guard DBusAuthHandshake.isAuthAccepted(serverLine: responseLine) else { return false }

      return writeRaw(Array(DBusAuthHandshake.beginLine.utf8))
    }

    /// Reads raw bytes (outside the binary message protocol — used only
    /// for the plain-text SASL handshake lines) until a newline or
    /// `timeout` elapses.
    private func readLine(timeout: Duration) -> String? {
      var collected: [UInt8] = []
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        var byte: UInt8 = 0
        let readCount = withUnsafeMutableBytes(of: &byte) { buffer in
          Glibc.read(fileDescriptor, buffer.baseAddress, 1)
        }
        guard readCount == 1 else { continue }
        if byte == UInt8(ascii: "\n") { break }
        collected.append(byte)
      }
      guard !collected.isEmpty else { return nil }
      return String(decoding: collected, as: UTF8.self)
    }

    private func writeRaw(_ bytes: [UInt8]) -> Bool {
      bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return false }
        return Glibc.write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
      }
    }
  #endif

  /// Sends `message` without waiting for any reply.
  @discardableResult
  public func send(_ message: DBusMessage) -> Bool {
    #if canImport(Glibc)
      return writeRaw(message.encoded())
    #else
      return false
    #endif
  }

  /// Blocks (up to `timeout`) until one complete `DBusMessage` has been
  /// read off the socket, or returns `nil` on timeout/error.
  public func receiveOneMessage(timeout: Duration) -> DBusMessage? {
    #if canImport(Glibc)
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if let decoded = tryDecodeBufferedMessage() { return decoded }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let readCount = chunk.withUnsafeMutableBytes { buffer in
          Glibc.read(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        guard readCount > 0 else { continue }
        state.withLock { $0.receiveBuffer.append(contentsOf: chunk.prefix(readCount)) }
      }
      return tryDecodeBufferedMessage()
    #else
      return nil
    #endif
  }

  private func tryDecodeBufferedMessage() -> DBusMessage? {
    state.withLock { state in
      guard let (message, consumed) = DBusMessage.decode(state.receiveBuffer) else { return nil }
      state.receiveBuffer.removeFirst(consumed)
      return message
    }
  }

  /// Sends `message` and blocks (up to `timeout`, TOTAL — not per read) for
  /// its matching `METHOD_RETURN`/`ERROR` reply (matched by
  /// `replySerial == message.serial`). Any other message received in the
  /// meantime (there should be none on a connection dedicated to calls —
  /// see this type's doc comment) is discarded.
  public func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage? {
    guard send(message) else { return nil }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let remaining = deadline - ContinuousClock.now
      guard let reply = receiveOneMessage(timeout: remaining) else { return nil }
      if reply.replySerial == message.serial { return reply }
    }
    return nil
  }
}

extension DBusConnection: ATSPIObjectCalling {}
