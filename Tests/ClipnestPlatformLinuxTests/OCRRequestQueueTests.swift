// OCRRequestQueueTests.swift
//
// P6-C (Linux OCR): unit tests for `OCRRequestQueue` — the bounded,
// drop-oldest backpressure queue in front of `OrtEnvironment.queue` (see
// that file's doc comment for why bounded + drop-oldest is a DIFFERENT,
// deliberate policy choice from `VisionTextRecognizer.recognitionQueue`'s
// unbounded FIFO on macOS). No ONNX Runtime dependency — `work`/`onDropped`
// are plain closures here, exactly like production, but production's
// closures happen to call into ORT while these just record what ran.
import Dispatch
import Foundation
import Testing

@testable import ClipnestLinuxOCR

/// Thread-safe recorder for what ran/was dropped, mutated only from
/// `OCRRequestQueue`'s own serial `queue` (`work`/`onDropped` closures) —
/// the lock exists purely to satisfy Swift 6 strict concurrency's
/// `@Sendable` capture checking, not because real contention is expected.
private final class OrderRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var completed: [Int] = []
  private var dropped: [Int] = []

  func recordCompleted(_ id: Int) {
    lock.lock()
    completed.append(id)
    lock.unlock()
  }

  func recordDropped(_ id: Int) {
    lock.lock()
    dropped.append(id)
    lock.unlock()
  }

  var completedSnapshot: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }

  var droppedSnapshot: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return dropped
  }
}

@Suite("OCRRequestQueue")
struct OCRRequestQueueTests {

  /// How long a test is willing to wait for GCD work to finish before
  /// failing — generous enough to never flake on a loaded CI box, short
  /// enough that a genuine hang (e.g. a regression reintroducing a
  /// deadlock) fails the test instead of hanging the suite forever.
  private static let testTimeoutSeconds: Double = 5

  @Test("Items run in FIFO order, one at a time, when never over capacity")
  func runsInFIFOOrderWithinCapacity() {
    let queue = DispatchQueue(label: "test.ocrRequestQueue.fifo")
    let requestQueue = OCRRequestQueue(queue: queue)
    let recorder = OrderRecorder()
    let group = DispatchGroup()

    for id in 1...3 {
      group.enter()
      requestQueue.enqueue(
        maxDepth: 10,
        work: {
          recorder.recordCompleted(id)
          group.leave()
        },
        onDropped: {
          recorder.recordDropped(id)
          group.leave()
        })
    }

    #expect(group.wait(timeout: .now() + Self.testTimeoutSeconds) == .success)
    #expect(recorder.completedSnapshot == [1, 2, 3])
    #expect(recorder.droppedSnapshot.isEmpty)
  }

  @Test(
    "Exceeding maxDepth drops the OLDEST still-waiting items, not the newest, and never drops the item already running"
  )
  func dropsOldestWhenOverCapacity() {
    let queue = DispatchQueue(label: "test.ocrRequestQueue.drop")
    let requestQueue = OCRRequestQueue(queue: queue)
    let recorder = OrderRecorder()
    let group = DispatchGroup()

    let blockerStarted = DispatchSemaphore(value: 0)
    let releaseBlocker = DispatchSemaphore(value: 0)

    // Item 0 occupies the queue (blocked) so items 1...5, enqueued below,
    // genuinely pile up in the backlog rather than each being pulled
    // straight into "running" before the next arrives.
    group.enter()
    requestQueue.enqueue(
      maxDepth: 2,
      work: {
        blockerStarted.signal()
        releaseBlocker.wait()
        recorder.recordCompleted(0)
        group.leave()
      },
      onDropped: {
        recorder.recordDropped(0)
        group.leave()
      })

    #expect(blockerStarted.wait(timeout: .now() + Self.testTimeoutSeconds) == .success)

    // maxDepth=2: item 1 is immediately promoted to "next up" as soon as
    // its bookkeeping runs (queue is idle from the backlog's point of view
    // the instant item 0 finishes), so the backlog only ever HOLDS items
    // 2..5 — and at maxDepth 2, enqueueing 4 more items over a 2-deep
    // backlog evicts exactly 2 of them (the oldest waiting each time: 2,
    // then 3), leaving 1 (already promoted to run), 4, and 5 to complete.
    for id in 1...5 {
      group.enter()
      requestQueue.enqueue(
        maxDepth: 2,
        work: {
          recorder.recordCompleted(id)
          group.leave()
        },
        onDropped: {
          recorder.recordDropped(id)
          group.leave()
        })
    }

    releaseBlocker.signal()

    #expect(group.wait(timeout: .now() + Self.testTimeoutSeconds) == .success)
    #expect(recorder.completedSnapshot == [0, 1, 4, 5])
    #expect(recorder.droppedSnapshot.sorted() == [2, 3])
  }

  @Test("currentBacklogCountForTesting reports 0 when nothing is waiting")
  func backlogCountStartsAtZero() {
    let queue = DispatchQueue(label: "test.ocrRequestQueue.count")
    let requestQueue = OCRRequestQueue(queue: queue)
    #expect(requestQueue.currentBacklogCountForTesting() == 0)
  }
}
