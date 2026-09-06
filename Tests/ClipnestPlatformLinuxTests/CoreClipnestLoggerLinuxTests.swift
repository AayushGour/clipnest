import ClipnestCore
import Foundation
import Glibc
import Testing

/// T-LX2 regression coverage: `ClipnestLogger`'s non-Apple branch used to
/// be a silent no-op for `info`/`debug` (and `error` wrote to a
/// fully-buffered stdout that a long-running daemon killed by a signal
/// never flushed) — see `Sources/ClipnestCore/Logging.swift`'s doc
/// comment for the full writeup. This test exercises the REAL emission
/// path (an actual `write(2)` to file descriptor 2), not just that a
/// format string is correct, since "does a byte actually leave the
/// process" was the whole bug.
///
/// `.serialized`: this test temporarily redirects the process's real
/// `STDERR_FILENO` (a single, process-wide resource) to a pipe so it can
/// capture what `ClipnestLogger` writes, and serializing this suite's own
/// tests removes any chance of them clobbering each other's redirection
/// window.
///
/// `.serialized` is NOT sufficient on its own, though, and the assertions
/// below therefore filter the captured bytes by this logger's own
/// `[LoggerTest]` tag rather than comparing the whole buffer. It only
/// orders THIS suite's tests; swift-testing still runs other suites
/// concurrently and — more importantly — the test runner writes its own
/// progress lines ("◇ Test ... started", "✔ Test ... passed") to fd 2,
/// which during the redirection window IS this pipe. A whole-buffer
/// equality check therefore captured runner output and failed
/// nondeterministically: measured failing on 2 of 3 consecutive runs even
/// at `swift test --jobs 1`, which would have turned any CI leg red at
/// random. Filtering keeps the assertion that actually matters — that
/// `ClipnestLogger` wrote exactly one correctly-tagged line to the real
/// fd 2 — while ignoring bytes this test never claimed to own.
@Suite("ClipnestLogger (Linux stderr emission) — T-LX2", .serialized)
struct ClipnestLoggerLinuxTests {
  @Test("error/info/debug each write one tagged line to real stderr, none are no-ops")
  func allThreeLevelsActuallyEmit() throws {
    let logger = ClipnestLogger(subsystem: ClipnestLog.subsystem, category: "LoggerTest")

    let errorOutput = try captureStderr { logger.error("boom") }
    #expect(taggedLines(in: errorOutput) == ["[LoggerTest] ERROR: boom"])

    let infoOutput = try captureStderr { logger.info("hello") }
    #expect(taggedLines(in: infoOutput) == ["[LoggerTest] INFO: hello"])

    let debugOutput = try captureStderr { logger.debug("trace") }
    #expect(taggedLines(in: debugOutput) == ["[LoggerTest] DEBUG: trace"])
  }
}

/// The lines of `captured` that this test's own logger emitted, identified
/// by the category tag `ClipnestLogger` prefixes every line with. Everything
/// else in the buffer belongs to the test runner (see the suite doc comment)
/// and is not this test's to assert on. Returning an array rather than a
/// joined string keeps the "exactly one line, no duplicates" part of the
/// original assertion.
private func taggedLines(in captured: String) -> [String] {
  captured
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map(String.init)
    .filter { $0.hasPrefix("[LoggerTest] ") }
}

private enum StderrCaptureError: Error {
  case pipeCreationFailed
  case dupFailed
}

/// Redirects `STDERR_FILENO` to a pipe for the duration of `body`, then
/// restores the real stderr and returns everything written in between.
/// Real file-descriptor plumbing, not a mock — `ClipnestLogger` has no
/// injectable sink by design (it's meant to stay a thin, dependency-free
/// shim; see its own doc comment), so proving it writes to the real fd 2
/// needs an actual fd 2 swap.
private func captureStderr(_ body: () -> Void) throws -> String {
  var pipeFDs: [Int32] = [0, 0]
  guard pipe(&pipeFDs) == 0 else { throw StderrCaptureError.pipeCreationFailed }
  let readEnd = pipeFDs[0]
  let writeEnd = pipeFDs[1]

  let savedStderr = dup(STDERR_FILENO)
  guard savedStderr >= 0 else { throw StderrCaptureError.dupFailed }
  dup2(writeEnd, STDERR_FILENO)
  close(writeEnd)

  body()

  // Restore BEFORE draining: dup2 back onto STDERR_FILENO closes the only
  // remaining reference to the pipe's write end, so the read loop below
  // sees EOF once it has drained everything already written instead of
  // blocking forever waiting for a writer that will never come.
  dup2(savedStderr, STDERR_FILENO)
  close(savedStderr)

  var collected = [UInt8]()
  var chunk = [UInt8](repeating: 0, count: 4096)
  while true {
    let bytesRead = chunk.withUnsafeMutableBytes { buffer in
      read(readEnd, buffer.baseAddress, buffer.count)
    }
    guard bytesRead > 0 else { break }
    collected.append(contentsOf: chunk.prefix(bytesRead))
  }
  close(readEnd)
  return String(decoding: collected, as: UTF8.self)
}
