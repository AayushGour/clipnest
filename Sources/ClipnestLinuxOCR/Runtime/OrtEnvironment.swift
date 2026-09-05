import Dispatch
import Foundation

// OrtEnvironment.swift
//
// P6-C (Linux OCR): owns the ONE shared `OrtEnv` and the lazily-created
// det/rec/cls `OrtSession`s, plus the dedicated serial dispatch queue every
// `OrtRun` call MUST execute on. This file is this task's direct answer to
// "do not repeat the T-HANG1 P0" (`.claude/logs/senior-dev.md`'s history:
// `VNImageRequestHandler.perform` was a synchronous-blocking call made from
// inside an `async` context, which pinned every cooperative-pool thread for
// 164+ seconds and starved an unrelated paste — see
// `VisionTextRecognizer.recognitionQueue`'s doc comment for the full
// post-mortem). `OrtRun` is EQUALLY synchronous-blocking; the fix is
// identical in shape.
//
// UNVERIFIED AGAINST REAL HEADERS: this file's actual ONNX Runtime C API
// calls (in `OrtSession.swift`) cannot be compiled or run anywhere in this
// task's environment — `onnxruntime_c_api.h` is not installable via `apt`
// and none is vendored into this repo or this task's Docker verification
// container (see this task's handoff notes for exactly what WAS verified).
// Every ORT-touching declaration here is behind `OrtRuntimeAvailability
// .isAvailable` (`#if CLIPNEST_HAS_ONNXRUNTIME`), so this file compiles to
// nothing observable when headers are absent — see that type's doc comment.
#if CLIPNEST_HAS_ONNXRUNTIME
  import COnnxRuntime
#endif

/// Owns ONE process-wide `OrtEnv` and the det/rec/cls sessions built on top
/// of it. All mutable state is confined to `queue` (a dedicated SERIAL
/// `DispatchQueue`, matching `VisionTextRecognizer.recognitionQueue`'s
/// pattern exactly) — this type is a plain, non-`Sendable`-by-inheritance
/// class whose every method asserts it is running on that queue via
/// `dispatchPrecondition`, rather than an `actor`: an `actor`'s isolation
/// is enforced through Swift Concurrency's cooperative pool, and hopping
/// onto/off of an actor still means the ACTUAL blocking `OrtRun` call would
/// need a further `Task.detached`-style escape to keep it off that pool —
/// simpler and more directly auditable to keep ORT access on one GCD queue
/// end-to-end, exactly like `VisionTextRecognizer` already does for Vision.
final class OrtEnvironment: @unchecked Sendable {

  /// Shared singleton — ONE `OrtEnv` for the process's lifetime (creating
  /// more than one is legal per the ONNX Runtime C API but wasteful; this
  /// module never needs more than one model family loaded at a time).
  static let shared = OrtEnvironment()

  /// Dedicated serial queue Swift Concurrency does not own — mirrors
  /// `VisionTextRecognizer.recognitionQueue` exactly (`qos: .utility`,
  /// serial). EVERY call into the ONNX Runtime C API — session creation,
  /// `Run`, release — happens here and ONLY here, asserted by
  /// `dispatchPrecondition(condition: .onQueue(queue))` at the top of every
  /// method below. A cooperative-pool thread must never be the one blocked
  /// inside `OrtRun`.
  let queue = DispatchQueue(label: "com.clipnest.linuxocr.ortEnvironment.queue", qos: .utility)

  /// How long a det/rec/cls session pair is kept resident after its last
  /// use before being released. 60s per this task's plan: "a resident pair
  /// costs ~120-200MB RSS, which a background clipboard manager must not
  /// hold forever." Named rather than inlined (no magic numbers).
  static let sessionIdleTimeout: TimeInterval = 60

  #if CLIPNEST_HAS_ONNXRUNTIME
    private var env: OpaquePointer?
    private var loadedSessions: OrtSessionSet?
  #endif
  private var idleReleaseWorkItem: DispatchWorkItem?

  private init() {}

  #if CLIPNEST_HAS_ONNXRUNTIME
    /// Runs `body` on `queue`, synchronously from the CALLER's perspective —
    /// callers are expected to already be off the cooperative pool
    /// themselves (see `OnnxTextRecognizer`'s own dedicated queue dispatch,
    /// which wraps this one further out); this is a plain `DispatchQueue
    /// .sync` hop, not an `async` suspension point, so no cooperative-pool
    /// thread is ever the one waiting on it.
    ///
    /// `tier` is part of the cache key (see `loadedSessionsOrCreate`)
    /// because it determines `intra_op_num_threads` and whether the
    /// orientation session is even loaded — a tier change (e.g. the user
    /// unplugs a laptop mid-session, changing `MachineCapacity.onBattery`)
    /// must rebuild sessions with the new tier's settings, not silently
    /// keep running the old tier's thread count forever.
    ///
    /// Deliberately declared ONLY inside this `#if` — its signature
    /// mentions `OrtSessionSet`, a type that itself only exists when
    /// `COnnxRuntime` resolved (see `OrtSession.swift`). Every call site
    /// (`OnnxTextRecognizer`) is itself behind the same
    /// `#if CLIPNEST_HAS_ONNXRUNTIME` guard, so this being unavailable in
    /// the "headers absent" build is never a problem for callers.
    func withSessions<Result>(
      modelPaths: OCRModelPaths, tier: OCRTierConfiguration, _ body: (OrtSessionSet) -> Result
    ) -> Result? {
      queue.sync {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let sessions = loadedSessionsOrCreate(modelPaths: modelPaths, tier: tier) else {
          return nil
        }
        scheduleIdleRelease()
        return body(sessions)
      }
    }

    private func loadedSessionsOrCreate(modelPaths: OCRModelPaths, tier: OCRTierConfiguration)
      -> OrtSessionSet?
    {
      dispatchPrecondition(condition: .onQueue(queue))
      if let existing = loadedSessions, existing.modelPaths == modelPaths,
        existing.intraOpNumThreads == tier.intraOpNumThreads,
        existing.hasOrientationSession == tier.runsOrientationClassifier
      {
        return existing
      }
      // Cache miss (first use, a tier change, or a model-path change):
      // release any stale session set, then create fresh.
      loadedSessions = nil
      guard let environment = ortEnvironmentOrCreate() else { return nil }
      guard
        let created = OrtSessionSet.create(
          environment: environment, modelPaths: modelPaths, tier: tier)
      else { return nil }
      loadedSessions = created
      return created
    }

    private func ortEnvironmentOrCreate() -> OpaquePointer? {
      dispatchPrecondition(condition: .onQueue(queue))
      if let env { return env }
      let created = OrtSessionSet.createEnvironment()
      env = created
      return created
    }
  #endif

  /// (Re)schedules the idle-release timer — called after every successful
  /// use, so the 60s window always measures time since the LAST use, not
  /// since the sessions were first created.
  private func scheduleIdleRelease() {
    dispatchPrecondition(condition: .onQueue(queue))
    idleReleaseWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.releaseIdleSessions()
    }
    idleReleaseWorkItem = workItem
    queue.asyncAfter(deadline: .now() + Self.sessionIdleTimeout, execute: workItem)
  }

  private func releaseIdleSessions() {
    dispatchPrecondition(condition: .onQueue(queue))
    #if CLIPNEST_HAS_ONNXRUNTIME
      loadedSessions = nil  // `OrtSessionSet.deinit` releases the native handles.
    #endif
  }
}
