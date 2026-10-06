// IBusCrashSafetyReconciliationGateTests.swift
//
// T-HANG-SELECT1 hygiene fix: `IBusCrashSafetyReconciliationGate` is pure
// Swift concurrency (a `Mutex<Void>` plus a generic `runBlocking`) with no
// socket/daemon dependency at all, unlike `IBusCrashSafetyReconciler`/
// `IBusCommitClient` (manual-verify only) -- so unlike those, this is
// exercised directly, deterministically, in CI.

import Foundation
import Synchronization
import Testing

@testable import ClipnestLinuxAppKit

/// `Mutex` is noncopyable (`~Copyable`) -- two concurrent `Task.detached`
/// closures can't each independently capture the SAME instance directly
/// (that would need to "send" a uniquely-owned value into two places at
/// once). Boxed in a `final class ...: Sendable` instead, exactly how
/// production code (`DBusConnection.state`, `IBusCommitClient.engineState`)
/// always keeps its own `Mutex` inside a class rather than passing it
/// around as a bare value.
private final class ConcurrencyCounters: Sendable {
  let activeCount = Mutex(0)
  let maxObservedConcurrency = Mutex(0)
}

/// A free function contending for `IBusCrashSafetyReconciliationGate`,
/// recording how many callers were simultaneously inside `runBlocking`'s
/// body via `counters`.
private func contendGateAndRecordConcurrency(_ counters: ConcurrencyCounters) {
  IBusCrashSafetyReconciliationGate.runBlocking {
    let nowActive = counters.activeCount.withLock { count -> Int in
      count += 1
      return count
    }
    counters.maxObservedConcurrency.withLock { $0 = max($0, nowActive) }
    // Long enough that, absent real mutual exclusion, the SECOND caller
    // would almost certainly enter while this one is still "active" --
    // short enough this test stays fast.
    Thread.sleep(forTimeInterval: 0.05)
    counters.activeCount.withLock { $0 -= 1 }
  }
}

@Suite("IBusCrashSafetyReconciliationGate")
struct IBusCrashSafetyReconciliationGateTests {
  @Test("runBlocking returns body's own result, unchanged")
  func returnsBodysResult() {
    let result = IBusCrashSafetyReconciliationGate.runBlocking { 42 }
    #expect(result == 42)
  }

  @Test(
    "two concurrent callers never run their bodies at the same time -- the exact property LinuxAppLifecycle's startup-vs-quit-time race depends on"
  )
  func serializesConcurrentCallers() async {
    let counters = ConcurrencyCounters()

    async let first: Void = Task.detached(priority: .userInitiated) {
      contendGateAndRecordConcurrency(counters)
    }.value
    async let second: Void = Task.detached(priority: .userInitiated) {
      contendGateAndRecordConcurrency(counters)
    }.value
    _ = await (first, second)

    #expect(counters.maxObservedConcurrency.withLock { $0 } == 1)
  }

  @Test("a caller that starts after another finishes is never blocked by it")
  func doesNotBlockAfterPreviousCallerFinished() {
    IBusCrashSafetyReconciliationGate.runBlocking {}
    let start = ContinuousClock.now
    IBusCrashSafetyReconciliationGate.runBlocking {}
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .seconds(1), "the gate must not hold a lock past its own runBlocking call")
  }
}
