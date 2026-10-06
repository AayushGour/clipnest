// SelfPipeTests.swift
//
// T-IBUS-CRASHWIRE: exercises `SelfPipe`'s write/drain mechanics directly
// against a REAL `pipe(2)` pair — fast, deterministic, and exactly as real
// in `swift test` as anywhere else, unlike the `sigaction`/`g_io_add_watch`
// wiring around it (`ProcessSignalShutdown`), which needs this process to
// actually receive a live OS signal or run a real `GMainLoop` to prove
// anything (manual-verify only, per this task's own brief — see
// `ProcessSignalShutdown.swift`'s top doc comment and this task's return
// message for what was verified live on the VM instead).

import Testing

@testable import ClipnestLinuxAppKit

@Suite("SelfPipe (T-IBUS-CRASHWIRE)")
struct SelfPipeTests {
  @Test("create() returns two distinct, valid file descriptors")
  func createReturnsDistinctDescriptors() {
    guard let pipe = SelfPipe.create() else {
      Issue.record("SelfPipe.create() failed on a platform that should support pipe(2)")
      return
    }
    defer { pipe.close() }
    #expect(pipe.readFileDescriptor >= 0)
    #expect(pipe.writeFileDescriptor >= 0)
    #expect(pipe.readFileDescriptor != pipe.writeFileDescriptor)
  }

  @Test("drain() on a freshly-created pipe with nothing written reports zero bytes")
  func drainOnEmptyPipeReportsZero() {
    guard let pipe = SelfPipe.create() else {
      Issue.record("SelfPipe.create() failed")
      return
    }
    defer { pipe.close() }
    #expect(pipe.drain() == 0)
  }

  @Test(
    "a wakeup posted via selfPipePostWakeupAsyncSignalSafe -- the ONLY call legal inside the real signal handler -- is observed by drain()"
  )
  func postWakeupIsObservedByDrain() {
    guard let pipe = SelfPipe.create() else {
      Issue.record("SelfPipe.create() failed")
      return
    }
    defer { pipe.close() }

    selfPipePostWakeupAsyncSignalSafe(writeFileDescriptor: pipe.writeFileDescriptor)

    #expect(pipe.drain() == 1)
  }

  @Test("multiple wakeups posted before a single drain() are all consumed in one call")
  func multipleWakeupsDrainedTogether() {
    guard let pipe = SelfPipe.create() else {
      Issue.record("SelfPipe.create() failed")
      return
    }
    defer { pipe.close() }

    for _ in 0..<5 {
      selfPipePostWakeupAsyncSignalSafe(writeFileDescriptor: pipe.writeFileDescriptor)
    }

    #expect(pipe.drain() == 5)
  }

  @Test(
    "drain() fully empties the pipe -- a second drain() call immediately after reports zero, matching the GLib IO-watch callback's own single-drain-per-wakeup usage"
  )
  func drainIsIdempotentOnceEmptied() {
    guard let pipe = SelfPipe.create() else {
      Issue.record("SelfPipe.create() failed")
      return
    }
    defer { pipe.close() }

    selfPipePostWakeupAsyncSignalSafe(writeFileDescriptor: pipe.writeFileDescriptor)
    _ = pipe.drain()

    #expect(pipe.drain() == 0)
  }
}
