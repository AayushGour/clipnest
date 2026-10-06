// SelfPipe.swift
//
// T-IBUS-CRASHWIRE: the classic POSIX self-pipe primitive — a `pipe(2)`
// pair used to safely wake a `GMainLoop` from inside an OS signal handler,
// where almost nothing else is legal to do (see `ProcessSignalShutdown
// .swift`'s top doc comment for the full design, and why this codebase
// needed it at all: there was no signal handler of any kind here before
// this task).
//
// Deliberately split out of `ProcessSignalShutdown` so its OWN write/drain
// mechanics are unit-tested directly against a REAL `pipe(2)` pair — fast,
// deterministic, and exactly as real in `swift test` as anywhere else,
// unlike `sigaction`/`g_io_add_watch`, which need this process to actually
// receive a live OS signal or run a real `GMainLoop` to prove anything
// (manual-verify only, matching `IBusCommitClient`/`ShellHelperClient`'s
// own precedent for live-socket code this test suite can't reach).

#if canImport(Glibc)
  import Glibc
#endif

/// A `pipe(2)` pair, both ends set non-blocking. `postWakeupAsyncSignalSafe`
/// (a bare free function below, NOT a member here) is the ONLY way to
/// signal this pipe that is safe to call from inside a raw OS signal
/// handler; every member on `SelfPipe` itself assumes ordinary,
/// non-signal execution and is meant to be called later, from the GLib
/// main loop.
struct SelfPipe {
  let readFileDescriptor: Int32
  let writeFileDescriptor: Int32

  #if canImport(Glibc)
    /// Creates a fresh pipe with both ends non-blocking. `nil` on any
    /// failure — matches this codebase's "degrade to unavailable, never
    /// crash" convention for a fallible OS resource. See
    /// `ProcessSignalShutdown.install`'s doc comment for what happens when
    /// this fails: SIGTERM/SIGINT simply keep their default (uncaught)
    /// termination behavior for this process, exactly as before this task.
    static func create() -> SelfPipe? {
      // `pipeResult`/`selfPipe`, deliberately NOT named `pipe`: a local
      // `let pipe` in this scope shadows Glibc's global `pipe(_:)`
      // function for the WHOLE function body (Swift resolves the
      // identifier lexically, not by declaration order), which silently
      // turns the syscall call below into an attempt to call a `SelfPipe`
      // value as a function — a real build error this file hit once
      // already, kept as a doc comment so nobody reintroduces the exact
      // same name.
      var descriptors: [Int32] = [-1, -1]
      let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer in
        pipe(buffer.baseAddress)
      }
      guard pipeResult == 0 else { return nil }
      let selfPipe = SelfPipe(
        readFileDescriptor: descriptors[0], writeFileDescriptor: descriptors[1])
      selfPipe.setNonBlocking(selfPipe.readFileDescriptor)
      selfPipe.setNonBlocking(selfPipe.writeFileDescriptor)
      return selfPipe
    }

    private func setNonBlocking(_ fileDescriptor: Int32) {
      let flags = fcntl(fileDescriptor, F_GETFL, 0)
      guard flags != -1 else { return }
      _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Drains every byte currently buffered on `readFileDescriptor`,
    /// non-blocking — returns the number of bytes actually read (0 means
    /// nothing was pending). Called from the GLib IO-watch callback
    /// (`ProcessSignalShutdown`), NEVER from the signal handler itself.
    /// Safe to call even when nothing is pending: `read()` on a
    /// non-blocking, empty pipe returns `-1`/`EAGAIN` immediately rather
    /// than blocking, which is exactly why both ends were set non-blocking
    /// at creation.
    @discardableResult
    func drain() -> Int {
      var totalBytesRead = 0
      var buffer = [UInt8](repeating: 0, count: 64)
      while true {
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
          read(readFileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard bytesRead > 0 else { break }
        totalBytesRead += bytesRead
      }
      return totalBytesRead
    }

    /// Closes both ends. Not called by production code today
    /// (`ProcessSignalShutdown` installs exactly one `SelfPipe` for the
    /// process's whole life — there is nothing to tear down before exit),
    /// kept for symmetry and so a test can create and discard many
    /// `SelfPipe`s without exhausting file descriptors.
    func close() {
      Glibc.close(readFileDescriptor)
      Glibc.close(writeFileDescriptor)
    }
  #else
    static func create() -> SelfPipe? { nil }
    @discardableResult
    func drain() -> Int { 0 }
    func close() {}
  #endif
}

#if canImport(Glibc)
  /// **Async-signal-safe by construction — the ONLY thing this function
  /// does is one `write()` syscall.** This is deliberately a bare, global
  /// function (not a method on `SelfPipe`) because the real OS signal
  /// handler that calls it (`ProcessSignalShutdown.shutdownSignalHandler`)
  /// is a `@convention(c)` function pointer, which cannot capture a
  /// `SelfPipe` instance — coding-standards.md's rule for this exact shape
  /// ("only async-signal-safe operations are legal there") is why this
  /// call is kept this small and this separate: a future edit to
  /// `SelfPipe` cannot accidentally make the signal-handler path do
  /// anything unsafe, because the signal handler never touches `SelfPipe`
  /// at all, only this one free function.
  ///
  /// The write's own result is deliberately ignored: there is nothing
  /// async-signal-safe this function COULD do differently on failure (no
  /// logging, no retry loop — both unsafe here), and a dropped wakeup byte
  /// is harmless as long as at least one signal delivery succeeds, since
  /// `SelfPipe.drain()` empties the pipe unconditionally rather than
  /// counting exact wakeups.
  func selfPipePostWakeupAsyncSignalSafe(writeFileDescriptor: Int32) {
    var byte: UInt8 = 1
    _ = write(writeFileDescriptor, &byte, 1)
  }
#endif
