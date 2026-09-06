import Foundation
import Testing

@testable import ClipnestPlatformLinux

#if canImport(Glibc)
  import Glibc
#endif

#if canImport(Glibc)
  /// Exercises `DBusFileDescriptorPassing`'s real `sendmsg(2)`/`recvmsg(2)`
  /// `SCM_RIGHTS` plumbing over a genuine `AF_UNIX` `socketpair(2)` — no
  /// D-Bus daemon involved (unlike `DBusConnection`, which needs a real
  /// bus to even complete its SASL handshake and is therefore
  /// manual-verify-only), so this runs as an ordinary, fully automated
  /// `swift test` in CI. `socketpair`/`mkstemp` are always available in an
  /// unprivileged Linux container — no network, no session bus, nothing
  /// this module's existing "no real bus in CI" constraint rules out.
  ///
  /// This is the layer directly BELOW `DBusConnection`: proving the raw
  /// kernel mechanism here, then proving `DBusMessage`'s wire format
  /// separately (`DBusUnixFDMarshallingTests`), is what makes the combined
  /// claim — "a real fd survives a real `DBusConnection` round trip" —
  /// trustworthy without needing a live `dbus-daemon` in this suite. The
  /// full combination (`DBusConnection` + a real bus) is proven manually
  /// in a container as this task's own acceptance criterion requires.
  @Suite("DBusFileDescriptorPassing — real socketpair, real SCM_RIGHTS")
  struct DBusFileDescriptorPassingTests {
    /// Creates a connected `AF_UNIX` `SOCK_STREAM` pair, matching exactly
    /// the socket type `DBusConnection` itself uses.
    private func makeSocketPair() -> (Int32, Int32) {
      var fds: [Int32] = [0, 0]
      let result = fds.withUnsafeMutableBufferPointer { buffer in
        socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, buffer.baseAddress)
      }
      #expect(result == 0, "socketpair(2) must succeed in any unprivileged Linux container")
      return (fds[0], fds[1])
    }

    /// A temp file (unlinked immediately — its fd alone keeps the backing
    /// storage alive, exactly like a memfd would) holding `contents`.
    private func makeFileDescriptor(contents: String) -> Int32 {
      var pathTemplate = Array("/tmp/dbus-fd-pass-test-XXXXXX".utf8CString)
      let fd = pathTemplate.withUnsafeMutableBufferPointer { buffer in
        mkstemp(buffer.baseAddress!)
      }
      #expect(fd >= 0)
      unlink(String(cString: pathTemplate))
      _ = contents.withCString { cString in Glibc.write(fd, cString, strlen(cString)) }
      _ = lseek(fd, 0, Int32(SEEK_SET))
      return fd
    }

    private func readAll(_ fd: Int32) -> String {
      _ = lseek(fd, 0, Int32(SEEK_SET))
      var buffer = [UInt8](repeating: 0, count: 4096)
      let readCount = buffer.withUnsafeMutableBytes { raw in
        Glibc.read(fd, raw.baseAddress, raw.count)
      }
      return String(decoding: buffer.prefix(max(readCount, 0)), as: UTF8.self)
    }

    @Test("a real fd for a file with known contents survives send→receive with matching bytes")
    func fileDescriptorSurvivesRoundTripWithMatchingBytes() {
      let (sender, receiver) = makeSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      let contents = "P8-C: SCM_RIGHTS round trip — \(UUID().uuidString)"
      let sourceFD = makeFileDescriptor(contents: contents)

      let sendOK = DBusFileDescriptorPassing.send(
        socket: sender, bytes: Array("PAYLOAD".utf8), fileDescriptors: [sourceFD])
      close(sourceFD)  // the sender's own copy — the kernel already duplicated it.
      #expect(sendOK)

      guard
        let (bytes, fileDescriptors) = DBusFileDescriptorPassing.receive(
          socket: receiver, maxBytes: 4096)
      else {
        Issue.record("receive returned nil")
        return
      }
      #expect(String(decoding: bytes, as: UTF8.self) == "PAYLOAD")
      #expect(fileDescriptors.count == 1)
      guard let receivedFD = fileDescriptors.first else { return }
      defer { close(receivedFD) }

      // Deliberately NOT asserting `receivedFD != sourceFD`: this process
      // already closed `sourceFD` above, so the kernel is free to (and, in
      // practice, often does) hand back that exact same NUMBER for the
      // duplicate `recvmsg` creates — Linux always allocates the
      // lowest-available fd. A coinciding number here proves nothing
      // either way; only the BYTES read back through it do.
      #expect(readAll(receivedFD) == contents)
    }

    @Test("sending with zero file descriptors falls back to a plain write — no ancillary data")
    func zeroFileDescriptorsIsPlainWrite() {
      let (sender, receiver) = makeSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      #expect(
        DBusFileDescriptorPassing.send(socket: sender, bytes: Array("hi".utf8), fileDescriptors: [])
      )
      guard
        let (bytes, fileDescriptors) = DBusFileDescriptorPassing.receive(
          socket: receiver, maxBytes: 64)
      else {
        Issue.record("receive returned nil")
        return
      }
      #expect(String(decoding: bytes, as: UTF8.self) == "hi")
      #expect(fileDescriptors.isEmpty)
    }

    @Test("multiple fds attached to one message all survive, in order, with distinct contents")
    func multipleFileDescriptorsSurviveInOrder() {
      let (sender, receiver) = makeSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      let contentsA = "first-\(UUID().uuidString)"
      let contentsB = "second-\(UUID().uuidString)"
      let fdA = makeFileDescriptor(contents: contentsA)
      let fdB = makeFileDescriptor(contents: contentsB)

      #expect(
        DBusFileDescriptorPassing.send(
          socket: sender, bytes: Array("TWO".utf8), fileDescriptors: [fdA, fdB]))
      close(fdA)
      close(fdB)

      guard
        let (_, fileDescriptors) = DBusFileDescriptorPassing.receive(socket: receiver, maxBytes: 64)
      else {
        Issue.record("receive returned nil")
        return
      }
      #expect(fileDescriptors.count == 2)
      defer { for fd in fileDescriptors { close(fd) } }
      #expect(readAll(fileDescriptors[0]) == contentsA)
      #expect(readAll(fileDescriptors[1]) == contentsB)
    }

    @Test("a message with fds mixed with a longer body still delivers correct bytes and fds")
    func fdsSurviveAlongsideALongerBody() {
      let (sender, receiver) = makeSocketPair()
      defer {
        close(sender)
        close(receiver)
      }
      let payload = Array(repeating: "x", count: 5000).joined()
      let fd = makeFileDescriptor(contents: "small")

      #expect(
        DBusFileDescriptorPassing.send(
          socket: sender, bytes: Array(payload.utf8), fileDescriptors: [fd]))
      close(fd)

      guard
        let (bytes, fileDescriptors) = DBusFileDescriptorPassing.receive(
          socket: receiver, maxBytes: 8192)
      else {
        Issue.record("receive returned nil")
        return
      }
      #expect(String(decoding: bytes, as: UTF8.self) == payload)
      #expect(fileDescriptors.count == 1)
      guard let receivedFD = fileDescriptors.first else { return }
      defer { close(receivedFD) }
      #expect(readAll(receivedFD) == "small")
    }
  }
#endif
