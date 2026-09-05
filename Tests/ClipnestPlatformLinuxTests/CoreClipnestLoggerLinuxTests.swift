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
/// capture what `ClipnestLogger` writes. Nothing else in this target logs
/// through `ClipnestLogger` during test execution (grep confirms it), but
/// serializing this suite's own tests removes any chance of them
/// clobbering each other's redirection window.
@Suite("ClipnestLogger (Linux stderr emission) — T-LX2", .serialized)
struct ClipnestLoggerLinuxTests {
  @Test("error/info/debug each write one tagged line to real stderr, none are no-ops")
  func allThreeLevelsActuallyEmit() throws {
    let logger = ClipnestLogger(subsystem: ClipnestLog.subsystem, category: "LoggerTest")

    let errorOutput = try captureStderr { logger.error("boom") }
    #expect(errorOutput == "[LoggerTest] ERROR: boom\n")

    let infoOutput = try captureStderr { logger.info("hello") }
    #expect(infoOutput == "[LoggerTest] INFO: hello\n")

    let debugOutput = try captureStderr { logger.debug("trace") }
    #expect(debugOutput == "[LoggerTest] DEBUG: trace\n")
  }
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
