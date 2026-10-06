// IBusDaemonLivenessTests.swift
//
// `IBusDaemonLiveness.isDaemonProcessAlive(pid:)` is the shared helper this
// task folded `IBusCommitClient`'s and `IBusCrashSafetyReconciler`'s
// previously-duplicated, disclosed copies into (reviewer non-blocking DRY
// finding). Neither original copy had its own direct test -- both were only
// exercised indirectly, through code paths needing a real `ibus-daemon`
// (manual-verify only). This suite pins the one thing that IS deterministic
// and needs no real daemon: `kill(pid, 0)`'s own liveness semantics against
// this process's own PID (definitely alive) and a PID far outside any real
// process table (definitely not).
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("IBusDaemonLiveness")
struct IBusDaemonLivenessTests {
  @Test("This process's own PID reports alive")
  func ownProcessReportsAlive() {
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    #expect(IBusDaemonLiveness.isDaemonProcessAlive(pid: ownPID))
  }

  @Test("An implausible PID far outside any real process table reports not alive")
  func implausiblePIDReportsNotAlive() {
    // Linux's own `pid_max` tops out at 4194304 even at its highest
    // configurable setting -- `Int32.max` is never a real, live process.
    #expect(!IBusDaemonLiveness.isDaemonProcessAlive(pid: Int32.max))
  }
}
