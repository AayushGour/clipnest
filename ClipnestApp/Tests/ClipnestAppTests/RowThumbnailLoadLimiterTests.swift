// RowThumbnailLoadLimiterTests.swift
//
// T-PF3 (P0 image-hang fix), D4: `ItemRow`'s row-thumbnail loader used to
// spawn one uncapped `Task.detached` per visible row — fast-scrolling an
// image-heavy history could run dozens of ~25 MB blob reads + decodes at
// once. `RowThumbnailLoadLimiter` bounds that. This suite proves the bound
// actually holds under real concurrent load, using a fresh, small-capacity
// instance (not the shared app-wide singleton) so the test is fast and
// doesn't touch process-wide state.
//
// Reviewer fix-round (2026-09-04): added coverage for the cancellation-aware
// FIFO (a waiter cancelled while queued must never run its body, and every
// permit must be correctly accounted for afterward). Every wait in this file
// is either a `withCheckedContinuation`-backed `Gate`/`Flag` the test itself
// controls, or a bounded `pollUntil` spin — no real, unbounded sleeps, so a
// regression fails fast instead of hanging CI.

import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import Clipnest

@Suite("RowThumbnailLoadLimiter")
struct RowThumbnailLoadLimiterTests {

  @Test("Never runs more permits concurrently than its configured cap")
  func neverExceedsConfiguredConcurrencyCap() async {
    let cap = 2
    let limiter = RowThumbnailLoadLimiter(maxConcurrentLoads: cap)
    let tracker = ConcurrencyTracker()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          await limiter.withPermit {
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(20))
            await tracker.exit()
          }
        }
      }
    }

    let observedMax = await tracker.maxConcurrent
    #expect(observedMax <= cap)
    // Also confirm the cap was actually exercised (not just trivially true
    // because nothing ran concurrently at all) — with 8 tasks contending for
    // 2 permits and a 20ms hold each, the max really should reach the cap.
    #expect(observedMax == cap)
  }

  @Test("A single permit still lets sequential work complete and return its value")
  func withPermitReturnsBodysResult() async {
    let limiter = RowThumbnailLoadLimiter(maxConcurrentLoads: 1)

    let result = await limiter.withPermit { () -> Int in 42 }

    #expect(result == 42)
  }

  @Test("A waiter cancelled while still queued never runs its body")
  func cancelledWaiterNeverRunsBody() async {
    let limiter = RowThumbnailLoadLimiter(maxConcurrentLoads: 1)
    let holderAcquired = Gate()
    let releaseHolder = Gate()
    let queuedBodyRan = Flag()

    // Task A takes the single permit and parks (under test control) so
    // Task B below is forced to queue rather than racing for a free permit.
    let holder = Task {
      await limiter.withPermit {
        await holderAcquired.open()
        await releaseHolder.wait()
      }
    }
    await holderAcquired.wait()

    let queued = Task {
      await limiter.withPermit {
        await queuedBodyRan.set(true)
      }
    }
    // Wait, deterministically and boundedly, until `queued` has actually
    // been enqueued in the FIFO — so cancelling it next exercises the
    // waiter-removal path, not just "already cancelled before acquire()
    // even ran" (which trivially also never runs the body, but wouldn't
    // prove the FIFO-removal logic itself).
    await pollUntil { await limiter.waitingCount >= 1 }

    queued.cancel()
    let queuedResult = await queued.value

    #expect(queuedResult == nil)  // withPermit never ran the body
    #expect(await queuedBodyRan.value == false)
    // The cancelled waiter must have been removed from the FIFO, not left
    // parked (which would eventually be granted a wasted permit).
    #expect(await limiter.waitingCount == 0)

    // Let the holder finish and release its permit.
    await releaseHolder.open()
    _ = await holder.value

    // The permit the cancelled waiter never consumed must still be there —
    // a fresh caller is admitted immediately.
    let admittedAfterCancellation = await limiter.withPermit { true }
    #expect(admittedAfterCancellation == true)
  }

  @Test("Permits are fully restored after a mix of cancelled and completed operations")
  func permitsFullyRestoredAfterMixedCancellationsAndCompletions() async {
    let cap = 2
    let limiter = RowThumbnailLoadLimiter(maxConcurrentLoads: cap)

    // Saturate the limiter so every additional caller below must queue.
    let holderAcquired = (0..<cap).map { _ in Gate() }
    let releaseHolders = (0..<cap).map { _ in Gate() }
    let holders = (0..<cap).map { index in
      Task {
        await limiter.withPermit {
          await holderAcquired[index].open()
          await releaseHolders[index].wait()
        }
      }
    }
    for gate in holderAcquired { await gate.wait() }

    // Queue more callers than there are permits — a realistic mix of "row
    // scrolled away" (cancelled) and "row is still visible, finishes
    // loading" (completes normally) during a fast-scroll burst.
    let queuedCount = 4
    let queuedTasks = (0..<queuedCount).map { _ in
      Task<Void?, Never> {
        await limiter.withPermit {}
      }
    }
    await pollUntil { await limiter.waitingCount >= queuedCount }

    // Cancel every other queued waiter while it's still parked.
    for index in stride(from: 0, to: queuedCount, by: 2) {
      queuedTasks[index].cancel()
    }

    // Release the holders so the surviving queued waiters can be granted
    // permits and complete normally.
    for gate in releaseHolders { await gate.open() }

    for task in holders { _ = await task.value }
    for task in queuedTasks { _ = await task.value }

    #expect(await limiter.waitingCount == 0)

    // Prove every permit made it back — not just "some permit" — by
    // admitting a full new batch of `cap` concurrent callers and confirming
    // they actually run at the configured concurrency, same assertion
    // style as `neverExceedsConfiguredConcurrencyCap` above.
    let tracker = ConcurrencyTracker()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<cap {
        group.addTask {
          await limiter.withPermit {
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(20))
            await tracker.exit()
          }
        }
      }
    }
    #expect(await tracker.maxConcurrent == cap)
  }

  // MARK: - Test helpers

  /// Spins via `Task.yield()` — never a real sleep — until `condition`
  /// becomes true, bounded by `maxPollIterations` so a genuine regression
  /// (e.g. a waiter that's never actually enqueued) fails the test instead
  /// of hanging CI forever.
  private func pollUntil(_ condition: () async -> Bool) async {
    for _ in 0..<Self.maxPollIterations {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record(
      "pollUntil: condition never became true within \(Self.maxPollIterations) iterations")
  }

  private static let maxPollIterations = 10_000

  /// Tracks concurrent `enter()`/`exit()` pairs to find the actual peak
  /// concurrency observed — an actor so increments/reads are race-free
  /// under real parallel execution.
  private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var maxConcurrent = 0

    func enter() {
      current += 1
      maxConcurrent = max(maxConcurrent, current)
    }

    func exit() {
      current -= 1
    }
  }

  /// A manually-controlled one-shot signal: `wait()` suspends until `open()`
  /// is called (from anywhere, any number of times — only the first counts),
  /// or returns immediately if `open()` already happened. Lets tests force
  /// an exact happens-before ordering between tasks without a real sleep.
  private actor Gate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
      guard !isOpen else { return }
      isOpen = true
      for continuation in continuations { continuation.resume() }
      continuations.removeAll()
    }

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { continuations.append($0) }
    }
  }

  /// A tiny actor-backed boolean, race-free to set/read from concurrent
  /// tasks — used to prove a queued body never ran.
  private actor Flag {
    private(set) var value = false

    func set(_ newValue: Bool) {
      value = newValue
    }
  }
}
