// OCRRequestQueue.swift
//
// P6-C (Linux OCR): a BOUNDED, drop-OLDEST work queue in front of the
// dedicated serial `OrtEnvironment.queue` (see that file's doc comment for
// why every `OrtRun` call must happen on one dedicated, Swift-Concurrency-
// unowned `DispatchQueue`, mirroring `VisionTextRecognizer.recognitionQueue`
// and the T-HANG1 post-mortem).
//
// Deliberately DIFFERENT policy from `VisionTextRecognizer.recognitionQueue`
// (macOS): that queue is a plain serial `DispatchQueue` with an UNBOUNDED
// backlog — "nothing ever dropped," a deliberate choice recorded in its own
// doc comment, appropriate because Vision recognition is comparatively
// cheap and macOS's threading budget is less CPU-constrained. This task's
// plan explicitly calls for the opposite on Linux: "a bounded queue with
// drop-oldest per tier" — a lower-power/battery/cgroup-limited machine
// running the heaviest tier it can barely sustain must not let its OCR
// backlog grow without bound (unbounded backlog == unbounded memory + an
// ever-growing latency tail that never recovers under sustained load).
// Dropping the OLDEST pending item (not the newest) keeps latency bounded
// for whatever's still queued, at the cost of losing the least-recently-
// useful item — and "losing" here is not a silent failure: a dropped
// item's `TextRecognizing.recognizeText` call simply resolves to `nil`,
// which is `ClipboardMonitor`'s ordinary "no text found" outcome; the
// existing `OCRBackfillCoordinator` (`Sources/ClipnestCore/OCR/`) already
// periodically retries `.image` items with `ocrText == nil`, so the
// product-level "OCR eventually happens" promise holds even though this
// specific queue is allowed to drop work under sustained overload.
//
// GCD's own `DispatchQueue` has no API to peek/cancel an already-submitted
// `.async` block, so bounding + drop-oldest needs this file's own explicit
// backlog array — `enqueue` appends to (and, over capacity, trims from the
// front of) `backlog`, and a separate self-perpetuating `runNext` chain is
// the ONLY thing that ever dequeues and executes an item, one at a time,
// which is what keeps `queue` (the actual ORT-calling queue) serialized to
// exactly one blocking `OrtRun` at a time regardless of how many `enqueue`
// calls race in concurrently.
import Dispatch

final class OCRRequestQueue: @unchecked Sendable {
  /// The dedicated serial queue every enqueued `work` closure ultimately
  /// runs on — bookkeeping (`backlog` mutation) and `work` execution both
  /// happen here, so both are naturally serialized with no separate lock
  /// needed. Always `OrtEnvironment.shared.queue` in production; injectable
  /// for tests that want a queue of their own to await completion on
  /// without cross-talking with other tests.
  private let queue: DispatchQueue

  /// One entry per still-waiting item. `work` is the actual (possibly
  /// blocking) pipeline call; `onDropped` fires if this item is evicted
  /// before it ever runs.
  private var backlog: [(work: @Sendable () -> Void, onDropped: @Sendable () -> Void)] = []
  private var isRunning = false

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  /// Enqueues `work`, bounded by `maxDepth` (from the active
  /// `OCRTierConfiguration.queueDepth` — passed per-call, not fixed at
  /// `init`, since the tier — and therefore the acceptable backlog depth —
  /// can change between calls as capacity/battery state changes). If the
  /// backlog is already at `maxDepth`, the OLDEST still-waiting entry
  /// (index 0 — NOT the item currently executing, which can't be
  /// interrupted mid-`OrtRun`; see this file's doc comment) is evicted and
  /// its `onDropped` fires, before `work` is appended.
  func enqueue(
    maxDepth: Int, work: @escaping @Sendable () -> Void, onDropped: @escaping @Sendable () -> Void
  ) {
    queue.async { [self] in
      dispatchPrecondition(condition: .onQueue(queue))
      if backlog.count >= max(0, maxDepth) {
        let evicted = backlog.removeFirst()
        evicted.onDropped()
      }
      backlog.append((work, onDropped))
      runNextIfIdle()
    }
  }

  /// Drains `backlog` one item at a time. Re-invoked at the end of each
  /// item's own execution (see `enqueue`'s scheduling below) rather than
  /// looping in place, so each item still runs as its own `queue.async`
  /// submission — keeping this queue's "one blocking call at a time"
  /// property visible to `dispatchPrecondition` checks inside `work`
  /// itself exactly the way a directly-submitted `queue.async { ortCall() }`
  /// would look.
  private func runNextIfIdle() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isRunning, !backlog.isEmpty else { return }
    isRunning = true
    let next = backlog.removeFirst()
    queue.async { [self] in
      dispatchPrecondition(condition: .onQueue(queue))
      next.work()
      isRunning = false
      runNextIfIdle()
    }
  }

  /// Number of items currently waiting (not counting one in flight) —
  /// exposed for tests only; production code has no need to inspect queue
  /// depth mid-flight.
  func currentBacklogCountForTesting() -> Int {
    queue.sync {
      dispatchPrecondition(condition: .onQueue(queue))
      return backlog.count
    }
  }
}
