import Synchronization

/// Serializes every call that reads/acts on the shared IBus crash-safety
/// marker BEFORE `LinuxAppEnvironment` exists — `LinuxAppLifecycle.launch()`'s
/// own startup reconciliation, `LinuxAppEnvironment.init`'s
/// `IBusCommitClient.resolveAndConnect` (which runs its OWN internal
/// reconcile pass — see `IBusCommitClient.start()` -> `reconcileAtStartup()`),
/// and `restoreIBusEngineBeforeQuit()`'s pre-`environment` fallback — so
/// none of them can ever execute concurrently against the same on-disk
/// settings file or the same live IBus daemon global-engine state.
///
/// **Why this exists, concretely (T-HANG-SELECT1 hygiene fix, startup path):**
/// before this fix, both `launch()`'s startup reconciliation and
/// `LinuxAppEnvironment.init`'s `IBusCommitClient.resolveAndConnect` ran
/// synchronously, INLINE, on the `@MainActor`/GTK thread — which,
/// incidentally, meant a shutdown signal's self-pipe GLib callback (itself
/// only ever dispatched on that SAME GTK main thread) could never fire
/// WHILE either call was in flight: mutual exclusion existed by accident,
/// as a side effect of the very freeze this task exists to remove. Moving
/// that blocking work off the GTK thread (so the compositor keeps
/// pumping/redrawing during the up-to-several-second worst case, instead of
/// raising a force-quit dialog) reopens exactly that window: a shutdown
/// signal arriving mid-reconcile could now dispatch a SECOND, genuinely
/// concurrent call into `IBusCrashSafetyReconciler.restoreIfMarkerPresent`
/// via `restoreIBusEngineBeforeQuit()`'s pre-`environment` branch — a
/// DIFFERENT, independently-`JSONFileKeyValueStore`-backed instance
/// (`PlatformDefaults.keyValueStore` is a computed property; every access
/// constructs a fresh one that reads `settings.json` fresh) racing the
/// in-flight one over the same file and the same daemon call. This gate
/// closes that window back up, deliberately, rather than relying on
/// incidental blocking.
///
/// Every genuinely blocking underlying operation this gate protects
/// (`DBusConnection.connect`/`.call`) is bounded by its own explicit,
/// NOW-ACTUALLY-ENFORCED timeout (`DBusSocketReceiveTimeout` — T-DBUSTIMEO1),
/// so a caller blocked waiting for this gate is itself bounded by the same
/// worst case, never stuck indefinitely behind a wedged peer.
///
/// Once `LinuxAppEnvironment` exists, `restoreIBusEngineIfNeeded()` routes
/// through its OWN, already-`SynchronizedKeyValueStore`-wrapped
/// `keyValueStore` instance instead (see that method's own doc comment) —
/// deliberately NOT this gate: by then every caller that could ever reach
/// this marker is `@MainActor`-isolated through `LinuxAppEnvironment`
/// itself, which already serializes them for free, and every call this
/// gate WOULD have protected has already run to completion (both
/// `launch()`'s own call and `LinuxAppEnvironment.init`'s
/// `IBusCommitClient.resolveAndConnect` are fully awaited to completion
/// strictly before `environment` is ever assigned in `launch()`).
enum IBusCrashSafetyReconciliationGate {
  private static let inFlight = Mutex<Void>(())

  /// The ONE synchronous entry point every "before `environment` exists"
  /// caller funnels through. Blocks the CALLING thread until any other
  /// in-flight call made through this same gate finishes, then runs `body`
  /// itself under the same exclusion.
  ///
  /// Callers that must not block their own thread (the `@MainActor`/GTK
  /// thread, at startup) call this from inside their own
  /// `Task.detached(priority: .userInitiated) { ... }.value` — matching
  /// `LinuxAppEnvironment.init`'s existing pattern for its other
  /// blocking/expensive startup steps. `restoreIBusEngineBeforeQuit()`'s
  /// pre-`environment` fallback calls this DIRECTLY, with no detach — see
  /// that method's own doc comment for why blocking briefly there, unlike
  /// at startup, is the correct, accepted trade-off (the caller is already
  /// committed to quitting, not serving a live user interaction).
  static func runBlocking<T>(_ body: () -> T) -> T {
    inFlight.withLock { _ in body() }
  }
}
