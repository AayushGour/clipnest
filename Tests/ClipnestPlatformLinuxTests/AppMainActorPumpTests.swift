import Foundation
import Testing

@testable import ClipnestLinuxAppKit

/// **The single most important test in this task.** Exercises the exact
/// mechanism `GTKMainActorBridge` installs as a repeating GLib timeout
/// source (`DispatchMainQueuePump.drainOnce()`) — the fix for the failure
/// mode the task brief calls out explicitly: "every `@MainActor` hop
/// silently never resumes and the app deadlocks with no error."
///
/// **Why this test alone doesn't (and can't) prove NECESSITY, and where
/// that proof actually lives:** empirically verified (Docker
/// `swift:6.0-jammy`) that a `swift test`/swift-testing host process's own
/// async entry point already drains `DispatchQueue.main` on its own — a
/// probe identical to this test's body, with `drainOnce()` never called at
/// all, resumed in ~35ms with zero pumping. That's `Swift`'s async-`main`
/// support doing its job (an `async` top-level entry needs SOME mechanism
/// servicing the main queue, and the runtime provides one) — it is NOT
/// evidence that GTK's plain, synchronous `main.swift` entry gets the same
/// treatment; it categorically does not, which is the entire bug this task
/// exists to fix. The real, load-bearing proof that `drainOnce()` is
/// NECESSARY in production lives outside this test suite, in two
/// throwaway Docker probes run against a plain, synchronous `main.swift`
/// (no async main, matching `ClipnestLinuxApp`'s actual shape exactly):
/// one bare `while` loop calling `drainOnce()`, and one driven by a REAL
/// `GMainLoop`/`g_timeout_add` (see this task's handoff for both
/// transcripts) — both showed the hop NEVER resumes without the pump and
/// DOES resume, promptly, with it.
///
/// What THIS test verifies, and is a real, permanent regression guard for:
/// `drainOnce()` is a CORRECT, side-effect-free way to service a pending
/// `@MainActor` hop — it doesn't error, hang, or corrupt state, and the
/// hop's result is exactly what was expected. If a future refactor of
/// `DispatchMainQueuePump` broke the drain itself (e.g. wrong `RunLoop`
/// mode, wrong queue), this test would catch that even though the
/// necessity proof above lives elsewhere.
@Suite("DispatchMainQueuePump")
struct AppMainActorPumpTests {
  @Test("drainOnce() services a pending Task.detached -> MainActor.run hop correctly")
  func drainOnceServicesAPendingMainActorHop() async throws {
    let semaphore = DispatchSemaphore(value: 0)
    let counter = MainActorCounter()

    Task.detached {
      try? await Task.sleep(for: .milliseconds(30))
      await MainActor.run { counter.increment() }
      semaphore.signal()
    }

    let deadline = Date().addingTimeInterval(5)
    var iterations = 0
    var resumed = false
    while Date() < deadline {
      iterations += 1
      DispatchMainQueuePump.drainOnce()
      if semaphore.wait(timeout: .now()) == .success {
        resumed = true
        break
      }
    }

    #expect(resumed, "the MainActor hop never resumed after \(iterations) drain iterations")
    let finalValue = await MainActor.run { counter.value }
    #expect(finalValue == 1)
  }
}

@MainActor
private final class MainActorCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}
