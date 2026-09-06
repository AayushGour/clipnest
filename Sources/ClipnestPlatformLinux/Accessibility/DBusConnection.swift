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
  /// Whether the daemon agreed to `NEGOTIATE_UNIX_FD` during the SASL
  /// handshake (see `DBusAuthHandshake.negotiateUnixFDLine`'s doc
  /// comment) — informational only; this module still ATTEMPTS
  /// fd-carrying sends/receives regardless (every real target it connects
  /// to is a modern dbus-daemon over a UNIX socket, which always agrees).
  /// Not behind `state`'s `Mutex`: it's written exactly once, entirely
  /// inside `performExternalAuth()`, which always completes before
  /// `connect(address:timeout:)` returns the connection to any caller —
  /// so by the time any other thread could observe this instance at all,
  /// the write already happened-before that observation.
  public private(set) var supportsFileDescriptorPassing = false

  private struct State {
    var nextSerial: UInt32 = 1
    var receiveBuffer: [UInt8] = []
    /// Real, owned file descriptors received via `SCM_RIGHTS` but not yet
    /// claimed by a fully-decoded message — see
    /// `tryDecodeBufferedMessage()`'s doc comment for the FIFO ordering
    /// invariant this depends on, and this type's "Received fds must be
    /// owned and closed" contract for who closes them.
    var pendingFileDescriptors: [Int32] = []
  }

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  deinit {
    #if canImport(Glibc)
      // Defensive only — every fd this connection ever buffers is meant to
      // be claimed by `tryDecodeBufferedMessage()` the moment its owning
      // message finishes decoding (see `pendingFileDescriptors`'s doc
      // comment). If the connection is torn down mid-read with some still
      // unclaimed (e.g. a reply arrived with its fds but the caller timed
      // out a moment earlier), closing them here is what keeps a dropped
      // connection from leaking real descriptors for the rest of the
      // process's life.
      for fd in state.withLock({ $0.pendingFileDescriptors }) { Glibc.close(fd) }
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

      // See `DBusAuthHandshake.negotiateUnixFDLine`'s doc comment: sent
      // unconditionally, for every connection, not just ones a caller
      // happens to know in advance will carry an `h` argument — skipping
      // this is exactly what silently breaks fd-carrying messages later
      // (the bytes go out fine; the daemon just never relays the
      // attached descriptors). A daemon that refuses (replies `ERROR`
      // rather than `AGREE_UNIX_FD`) doesn't fail the WHOLE connection —
      // ordinary, non-fd traffic must keep working either way.
      guard writeRaw(Array(DBusAuthHandshake.negotiateUnixFDLine.utf8)) else { return false }
      if let negotiationReply = readLine(timeout: .seconds(1)) {
        supportsFileDescriptorPassing = DBusAuthHandshake.isUnixFDAgreed(
          serverLine: negotiationReply)
      }

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

    private func writeRaw(_ bytes: [UInt8], attachingFileDescriptors: [Int32] = []) -> Bool {
      DBusFileDescriptorPassing.send(
        socket: fileDescriptor, bytes: bytes, fileDescriptors: attachingFileDescriptors)
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

  /// Sends `message` with `attachingFileDescriptors` riding along as
  /// `SCM_RIGHTS` ancillary data on the same `sendmsg` call (see
  /// `DBusFileDescriptorPassing.send`'s doc comment for why they must
  /// share one syscall). `message.unixFileDescriptorCount` is always
  /// overridden to `attachingFileDescriptors.count` before encoding —
  /// the array actually being attached is the one source of truth for
  /// the `UNIX_FDS` header field, so a caller can never send a `.unixFD`
  /// body value whose index is out of range of what's really attached, or
  /// forget to set the count at all.
  @discardableResult
  public func send(_ message: DBusMessage, attachingFileDescriptors: [Int32]) -> Bool {
    #if canImport(Glibc)
      var outgoing = message
      outgoing.unixFileDescriptorCount = attachingFileDescriptors.count
      return writeRaw(outgoing.encoded(), attachingFileDescriptors: attachingFileDescriptors)
    #else
      return false
    #endif
  }

  /// Blocks (up to `timeout`) until one complete `DBusMessage` has been
  /// read off the socket, or returns `nil` on timeout/error.
  ///
  /// If the message carries attached file descriptors
  /// (`unixFileDescriptorCount > 0`), they are received correctly (never
  /// truncated — see `DBusFileDescriptorPassing`) but then immediately
  /// CLOSED, since this overload has no way to hand them to a caller that
  /// didn't ask for them. Every call site in this app that can
  /// legitimately receive an fd-carrying message (`ShellHelperClient`'s
  /// payload methods) uses `receiveOneMessageWithFileDescriptors(timeout:)`
  /// instead; this defensive close exists purely so an ordinary,
  /// non-fd-aware caller can never silently leak one.
  public func receiveOneMessage(timeout: Duration) -> DBusMessage? {
    guard let (message, fileDescriptors) = receiveOneMessageWithFileDescriptors(timeout: timeout)
    else { return nil }
    closeFileDescriptors(fileDescriptors)
    return message
  }

  /// Same contract as `receiveOneMessage(timeout:)`, but also returns any
  /// real file descriptors the message carried. Every returned descriptor
  /// is a REAL, now-open fd in this process from this call onward — the
  /// CALLER owns it and must close it exactly once (reading it, e.g. via
  /// `ReadClipboard`'s payload, then closing; or closing outright if it
  /// turns out not to be needed).
  public func receiveOneMessageWithFileDescriptors(
    timeout: Duration
  ) -> (message: DBusMessage, fileDescriptors: [Int32])? {
    #if canImport(Glibc)
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if let decoded = tryDecodeBufferedMessage() { return decoded }
        guard
          let (bytes, fileDescriptors) = DBusFileDescriptorPassing.receive(
            socket: fileDescriptor, maxBytes: DBusConnectionDefaults.readChunkByteCount)
        else { continue }
        state.withLock {
          $0.receiveBuffer.append(contentsOf: bytes)
          $0.pendingFileDescriptors.append(contentsOf: fileDescriptors)
        }
      }
      return tryDecodeBufferedMessage()
    #else
      return nil
    #endif
  }

  /// Decodes the oldest complete message sitting in `receiveBuffer` (if
  /// any) and, if it carries attached fds, claims that many off the FRONT
  /// of `pendingFileDescriptors`.
  ///
  /// **Why FIFO-by-position is correct or here, not just convenient:**
  /// `SCM_RIGHTS` ancillary data is associated by the kernel with whichever
  /// bytes a specific `sendmsg`/`recvmsg` call carried (`unix(7)`), NOT
  /// with "message N" as this module's own framing understands it. But
  /// every message this app ever sends with attached fds is written by
  /// EXACTLY ONE `sendmsg` call (see `DBusConnection.send(_:
  /// attachingFileDescriptors:)`), and messages on one connection are
  /// always fully decoded in the same order their bytes arrived (this type
  /// never reorders or replays `receiveBuffer`). So the Nth message to
  /// finish decoding is always the Nth message whose fds were appended to
  /// `pendingFileDescriptors` — claiming from the front, in order, is
  /// exactly right for this module's own strictly-sequential
  /// send/receive usage. This would NOT hold for a connection that
  /// pipelined multiple in-flight requests concurrently; this module never
  /// does that (see `DBusConnection`'s own top-level doc comment on using
  /// two separate connections instead of multiplexing one).
  private func tryDecodeBufferedMessage() -> (message: DBusMessage, fileDescriptors: [Int32])? {
    state.withLock { state in
      guard let (message, consumed) = DBusMessage.decode(state.receiveBuffer) else { return nil }
      state.receiveBuffer.removeFirst(consumed)
      let claimedCount = min(message.unixFileDescriptorCount, state.pendingFileDescriptors.count)
      let fileDescriptors = Array(state.pendingFileDescriptors.prefix(claimedCount))
      state.pendingFileDescriptors.removeFirst(claimedCount)
      return (message, fileDescriptors)
    }
  }

  #if canImport(Glibc)
    private func closeFileDescriptors(_ fileDescriptors: [Int32]) {
      for fd in fileDescriptors { Glibc.close(fd) }
    }
  #else
    private func closeFileDescriptors(_ fileDescriptors: [Int32]) {}
  #endif

  /// Sends `message` and blocks (up to `timeout`, TOTAL — not per read) for
  /// its matching `METHOD_RETURN`/`ERROR` reply (matched by
  /// `replySerial == message.serial`). Any other message received in the
  /// meantime (there should be none on a connection dedicated to calls —
  /// see this type's doc comment) is discarded — and if it happened to
  /// carry fds, they are closed rather than leaked.
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

  /// Same contract as `call(_:timeout:)`, but for a request that attaches
  /// real file descriptors (`attachingFileDescriptors` — index `i`'s real
  /// fd is whatever `.unixFD(UInt32(i))` in `message`'s body should
  /// resolve to) and/or expects a reply that carries some back. Every fd
  /// in the returned tuple's `fileDescriptors` is CALLER-OWNED — see
  /// `receiveOneMessageWithFileDescriptors(timeout:)`'s contract.
  public func call(
    _ message: DBusMessage, attachingFileDescriptors: [Int32], timeout: Duration
  ) -> (message: DBusMessage, fileDescriptors: [Int32])? {
    guard send(message, attachingFileDescriptors: attachingFileDescriptors) else { return nil }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let remaining = deadline - ContinuousClock.now
      guard let (reply, fileDescriptors) = receiveOneMessageWithFileDescriptors(timeout: remaining)
      else { return nil }
      if reply.replySerial == message.serial { return (reply, fileDescriptors) }
      closeFileDescriptors(fileDescriptors)
    }
    return nil
  }
}

/// `4096`, factored out because `receiveOneMessageWithFileDescriptors`
/// needs the exact same chunk size the original plain-`read` loop always
/// used — kept in one place per coding-standards.md's "no magic numbers
/// used more than once" rule.
enum DBusConnectionDefaults {
  static let readChunkByteCount = 4096
}

extension DBusConnection: ATSPIObjectCalling {}
