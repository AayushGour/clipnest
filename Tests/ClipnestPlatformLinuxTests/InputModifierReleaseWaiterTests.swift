import Foundation
import Synchronization
import Testing

@testable import ClipnestPlatformLinux

/// A queue of canned mask reads — each call to `currentModifierMask()`
/// pops the next one (repeating the last once exhausted), so tests can
/// script "held, held, released" sequences without a real X display.
private final class FakeModifierMaskReader: ModifierMaskReading, @unchecked Sendable {
  private var queue: [ModifierMask]
  private(set) var readCount = 0

  init(_ queue: [ModifierMask]) { self.queue = queue }

  func currentModifierMask() -> ModifierMask {
    readCount += 1
    guard !queue.isEmpty else { return [] }
    return queue.count == 1 ? queue[0] : queue.removeFirst()
  }
}

/// A plain `Int` counter safe to mutate from inside a `@Sendable` closure
/// (`ModifierReleaseWaiter`'s injected `sleep` parameter) — a bare
/// captured `var` is rejected by strict concurrency ("mutation of captured
/// var in concurrently-executing code") even though `waitForRelease()` is
/// actually fully synchronous; `Mutex` is the same synchronization
/// primitive the production code (`DBusConnection`, `ATSPIFocusTracker`)
/// already uses for real shared mutable state.
private final class SleepCounter: Sendable {
  private let count = Mutex<Int>(0)

  func increment() { count.withLock { $0 += 1 } }
  var value: Int { count.withLock { $0 } }
}

@Suite("ModifierReleaseWaiter")
struct ModifierReleaseWaiterTests {
  @Test("returns released immediately when nothing is held")
  func releasedImmediately() {
    let reader = FakeModifierMaskReader([[]])
    let waiter = ModifierReleaseWaiter(
      reader: reader, pollInterval: .milliseconds(10), releaseCeiling: .milliseconds(400),
      sleep: { _ in Issue.record("should not sleep when already released") })
    #expect(waiter.waitForRelease() == .released)
    #expect(reader.readCount == 1)
  }

  @Test("polls until modifiers are released, without exceeding the ceiling")
  func pollsUntilReleased() {
    let sleepCount = SleepCounter()
    let reader = FakeModifierMaskReader([.control, .control, []])
    let waiter = ModifierReleaseWaiter(
      reader: reader, pollInterval: .milliseconds(10), releaseCeiling: .milliseconds(400),
      sleep: { _ in sleepCount.increment() })
    #expect(waiter.waitForRelease() == .released)
    #expect(sleepCount.value == 2)
  }

  @Test("times out rather than sending with a modifier still held")
  func timesOutWithoutSending() {
    let sleepCount = SleepCounter()
    let reader = FakeModifierMaskReader([.control])
    let waiter = ModifierReleaseWaiter(
      reader: reader, pollInterval: .milliseconds(10), releaseCeiling: .milliseconds(40),
      sleep: { _ in sleepCount.increment() })
    #expect(waiter.waitForRelease() == .timedOut)
    // Ceiling 40ms / 10ms interval = 4 sleeps before giving up.
    #expect(sleepCount.value == 4)
  }
}
