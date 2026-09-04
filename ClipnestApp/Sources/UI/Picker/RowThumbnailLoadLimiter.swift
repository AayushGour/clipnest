// RowThumbnailLoadLimiter.swift
//
// T-PF3 (P0 image-hang fix), D4 (item 4 of the required work): `ItemRow`'s
// `ItemIconThumbnail.load()` runs once per visible row via `.task(id:)`.
// Fast-scrolling an image-heavy history can bring dozens of rows on screen
// within the same runloop tick, each spawning its own `Task.detached` that
// reads a blob (real screenshots run tens of MB, see
// `.claude/logs/stress-artifacts/senior-dev-after-fix-run.txt`) and decodes
// it. With no cap, all of them could run their read+decode at once —
// competing for disk I/O and CPU at exactly the moment the user is actively
// scrolling, which is what made the hang worse the faster/more you scrolled.
//
// This actor-backed counting semaphore bounds how many of those loads run
// their body concurrently; callers past the cap suspend on a FIFO queue
// (parked via `withCheckedContinuation`, not polling/spinning) until a
// permit frees up.
//
// Reviewer fix-round (2026-09-04): the queued wait is now
// cancellation-aware. `ItemIconThumbnail.load()` runs inside `.task(id:)`,
// which SwiftUI cancels the instant a row scrolls off-screen/gets recycled
// — exactly the fast-scroll scenario this limiter exists to protect. Before
// this fix, a cancelled waiter stayed parked in the FIFO and, once its turn
// eventually came, still ran the full blob read + decode for a row nobody
// could see, delaying the permit for rows the user IS actually looking at.
// `acquire()` now uses `withTaskCancellationHandler` to remove a cancelled
// waiter from the FIFO and resume it WITHOUT a permit — `withPermit` never
// invokes `body` in that case. See `acquire()`'s doc comment for the exact
// race-freedom argument.

import Foundation

actor RowThumbnailLoadLimiter {
  /// Concurrent row-thumbnail loads allowed at once, app-wide. Matches the
  /// performance-core count on the base Apple Silicon Macs this app ships
  /// for (M-series: 4 performance cores) — enough concurrency to keep
  /// scrolling feeling responsive without letting a fast scroll through an
  /// image-heavy history saturate the machine with dozens of simultaneous
  /// disk reads + decodes.
  static let defaultMaxConcurrentLoads = 4

  /// The app-wide limiter every `ItemRow` thumbnail load shares. Tests
  /// construct their own instance (see `init(maxConcurrentLoads:)`) instead
  /// of reusing this one, so they can pick a small cap and stay fast/
  /// deterministic without touching shared global state.
  static let shared = RowThumbnailLoadLimiter(maxConcurrentLoads: defaultMaxConcurrentLoads)

  /// A single queued caller waiting for a permit. `id` lets the
  /// cancellation handler installed in `acquire()` (which runs OUTSIDE this
  /// actor's isolation — see that method's doc comment) find and remove
  /// exactly this waiter from `waiters` without disturbing FIFO order for
  /// anyone else.
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let maxConcurrentLoads: Int
  private var availablePermits: Int
  private var waiters: [Waiter] = []

  init(maxConcurrentLoads: Int) {
    self.maxConcurrentLoads = maxConcurrentLoads
    self.availablePermits = maxConcurrentLoads
  }

  /// Test-only observability hook: how many callers are currently queued
  /// (parked past the concurrency cap, not yet granted a permit). Exists so
  /// `RowThumbnailLoadLimiterTests` can synchronize on "this waiter has
  /// actually been enqueued" without a real sleep — see that file. Plain
  /// `internal` read-only access (no `@testable` production caller reads
  /// this); it carries no behavior of its own.
  var waitingCount: Int { waiters.count }

  /// Runs `body` once a permit is available, releasing the permit when
  /// `body` returns, and returns its result.
  ///
  /// Returns `nil`, and never invokes `body` at all, if the calling `Task`
  /// is cancelled while still queued for a permit (see `acquire()`) — the
  /// row that requested this load has scrolled away, so there is nothing to
  /// load for. Once `body` DOES start running (a permit was actually
  /// granted), it always runs to completion and its permit is always
  /// released — a later cancellation of the caller doesn't abort a load
  /// already in flight, matching every other cancellable await in this
  /// app: `.task(id:)` simply re-runs from scratch if the row comes back.
  @discardableResult
  func withPermit<T: Sendable>(_ body: @Sendable () async -> T) async -> T? {
    guard await acquire() else { return nil }
    let result = await body()
    release()
    return result
  }

  /// Waits for a permit, honoring `Task` cancellation while queued. Returns
  /// `true` once a permit has actually been granted, `false` if the calling
  /// task was cancelled before that happened — no permit is ever consumed
  /// in the `false` case.
  ///
  /// `withTaskCancellationHandler`'s `onCancel` closure is `@Sendable` and
  /// can run concurrently with `operation`, on whatever thread cancels the
  /// task — it does NOT run on this actor's isolation, so it can't touch
  /// `waiters` directly. It only schedules `cancelWaiter(id:)` back onto the
  /// actor. Because the actor serializes all access to `waiters`, exactly
  /// one of two outcomes happens for any given waiter, never both:
  ///   1. `cancelWaiter(id:)` runs before `release()` reaches this waiter —
  ///      it's still in `waiters`, gets removed, and its continuation
  ///      resumes `false`. No permit was ever handed out for it, and
  ///      removing it from the middle of the array (rather than requiring
  ///      it be first) leaves FIFO order intact for everyone still queued.
  ///   2. `release()` reaches this waiter first — it's dequeued and resumed
  ///      `true` (permit granted). `cancelWaiter(id:)` then finds it already
  ///      gone from `waiters` and is a no-op: the permit was already
  ///      committed, so the caller proceeds despite the late cancellation,
  ///      same as any other narrowly-lost cancellation race elsewhere in
  ///      Swift concurrency. Either way there is exactly one resume per
  ///      waiter (no double-resume) and exactly one permit accounted for
  ///      per grant (no leak, no double-release).
  ///
  /// The `Task.isCancelled` fast-path below additionally ensures an
  /// already-cancelled caller never even takes an immediately-available
  /// permit, so it never runs `body` either.
  private func acquire() async -> Bool {
    if Task.isCancelled { return false }
    if availablePermits > 0 {
      availablePermits -= 1
      return true
    }

    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  /// Removes the queued waiter with `id`, if it's still waiting, and
  /// resumes it with `false`. No-op if it already got its permit — see
  /// `acquire()`'s doc comment for why that's the correct, race-free
  /// outcome in that ordering.
  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }

  /// Hands the freed permit directly to the next waiter (if any) rather than
  /// incrementing `availablePermits` and letting it race to `acquire()` —
  /// avoids a spurious extra `acquire()` decrement, and this actor's
  /// serialized isolation is what makes the hand-off race-free.
  private func release() {
    if waiters.isEmpty {
      availablePermits += 1
    } else {
      waiters.removeFirst().continuation.resume(returning: true)
    }
  }
}
