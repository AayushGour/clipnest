import Foundation

/// **The fix for the single most dangerous item in the Linux port.**
///
/// GTK owns the process's one real event loop via `g_main_loop_run`
/// (`ClipnestGTKApplication.runMainLoop()`), but every collaborator this
/// composition root wires up — `ClipboardMonitor`, `FrontmostAppTracker`,
/// `SnippetExpander`, `PickerViewModel` — is `@MainActor`, and on Linux
/// `MainActor`'s default executor is backed by `DispatchQueue.main` (there
/// is no Cocoa/`CFRunLoop` run loop pumping it the way `NSApplication.run()`
/// does on macOS). Nothing in this process ever calls `dispatchMain()` or
/// drives `RunLoop.main` on its own — GTK's loop is the only thing running
/// — so without this fix every single `@MainActor` hop (`Task { @MainActor
/// in ... }`, `await MainActor.run { ... }`, an `async` call into any of the
/// types above) enqueues a job onto `DispatchQueue.main` that nothing ever
/// services. There is no crash, no error, no log line — the process looks
/// completely alive and the GTK window keeps painting; the hop just never
/// resumes. This is exactly the class of failure `AppMainActorPumpTests`
/// (`Tests/ClipnestPlatformLinuxTests/AppMainActorPumpTests.swift`) exists
/// to catch before it ships.
///
/// **The mechanism, verified empirically** (Docker `swift:6.0-jammy`, both
/// in isolation and driven by a real `GMainLoop`/`g_timeout_add` — see this
/// task's handoff for the two throwaway probe packages and their captured
/// output): `RunLoop.main` on Linux (`swift-corelibs-foundation`) wraps a
/// `CFRunLoop` whose `__CFRunLoopRun` DOES service `DispatchQueue.main`
/// directly — when the run loop's "dispatch port" wakes (i.e., work was
/// enqueued via `dispatch_async(dispatch_get_main_queue(), ...)`, which is
/// exactly what a `MainActor` hop does under the hood on this platform),
/// `CFRunLoopRunInMode` calls `_dispatch_main_queue_callback_4CF`, which
/// runs every pending main-queue block before returning. Calling
/// `RunLoop.main.run(mode:before:)` with a near-immediate `limitDate`
/// therefore drains whatever is currently queued (if anything) and returns
/// promptly either way — it is a bounded, non-blocking-forever poll, safe
/// to call from a GLib timeout callback on every tick.
///
/// This never touches `Dispatch`'s private API and requires no experimental
/// SPI (`_spi(ExperimentalCustomExecutors)`'s `ExecutorFactory`/
/// `MainExecutor` protocols were investigated first — they are the
/// "textbook" answer, but require `StdlibDeploymentTarget 6.3`; this
/// project's hard verification gate is `swift:6.0-jammy`, so that path is
/// not available here and is left as a documented future upgrade once the
/// toolchain floor moves).
///
/// `GTKMainActorBridge` is the production caller (a `g_timeout_add` source,
/// installed once from `main.swift`); `AppMainActorPumpTests` calls this
/// same function directly, off any GLib loop, to prove the mechanism itself
/// resumes a real `Task.detached -> MainActor.run` hop within a bounded
/// number of calls.
public enum DispatchMainQueuePump {
  /// How long a single drain call is allowed to block waiting for the next
  /// dispatch-port wakeup before giving up and returning control to the
  /// caller (GTK's loop, so this must stay short — see
  /// `GTKMainActorBridge.tickIntervalMilliseconds`). Not zero: `seconds:
  /// 0.0` is documented as "instant timeout, effectively polling," which
  /// starves a job that gets enqueued a few microseconds after the call
  /// starts; a few milliseconds of slack costs nothing perceptible at
  /// GTK's own tick rate and measurably improves how quickly a hop
  /// resumes.
  public static let defaultBudget: TimeInterval = 0.005

  /// Drains at most one pass of whatever is currently pending on
  /// `DispatchQueue.main` (which is what every `@MainActor` hop in this
  /// process actually enqueues onto) and returns — never blocks
  /// indefinitely. Safe to call from a plain, synchronous, non-`async`
  /// context only (`RunLoop.run(mode:before:)` is unavailable from an
  /// `async` context by design); every real caller in this codebase is a
  /// GLib C callback, which is exactly that.
  public static func drainOnce(budget: TimeInterval = DispatchMainQueuePump.defaultBudget) {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: budget))
  }
}
