import Testing

#if canImport(Glibc)
  import Glibc
#endif

#if canImport(Glibc)
  /// A connected `AF_UNIX` `SOCK_STREAM` pair, matching exactly the socket
  /// type `DBusConnection` itself uses — no D-Bus daemon involved, so tests
  /// built on this run as ordinary, fully automated `swift test` in CI
  /// (see `DBusFileDescriptorPassingTests`'s own doc comment for why that
  /// distinction matters for this module).
  ///
  /// Shared by `DBusFileDescriptorPassingTests` and
  /// `DBusSocketReceiveTimeoutTests` — factored out once a second test file
  /// needed the identical pair (coding-standards.md: extract on the second
  /// real duplicate, not preemptively).
  func makeUnixSocketPair(sourceLocation: SourceLocation = #_sourceLocation) -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { buffer in
      socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, buffer.baseAddress)
    }
    #expect(
      result == 0, "socketpair(2) must succeed in any unprivileged Linux container",
      sourceLocation: sourceLocation)
    return (fds[0], fds[1])
  }
#endif
