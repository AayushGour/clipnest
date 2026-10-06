// OrtEnvironment.swift
//
// P6-C / P8-B (Linux OCR): owns the ONE shared `OrtEnv` and the
// lazily-created det/rec/cls `OrtSession`s, plus the dedicated serial
// dispatch queue every `OrtRun` call MUST execute on. This file is this
// task's direct answer to "do not repeat the T-HANG1 P0"
// (`.claude/logs/senior-dev.md`'s history: `VNImageRequestHandler.perform`
// was a synchronous-blocking call made from inside an `async` context,
// which pinned every cooperative-pool thread for 164+ seconds and starved
// an unrelated paste — see `VisionTextRecognizer.recognitionQueue`'s doc
// comment for the full post-mortem). `OrtRun` is EQUALLY
// synchronous-blocking; the fix is identical in shape.
//
// VERIFIED AGAINST THE REAL HEADER as of P8-B — see `OrtSession.swift`'s
// top comment. This file is compiled UNCONDITIONALLY on Linux now (`import
// COnnxRuntime` can never fail to resolve — see `shim.h`), unlike the
// earlier `#if CLIPNEST_HAS_ONNXRUNTIME` compile-time gate this file used
// to carry. Every ORT-touching call this type makes is only ever REACHED
// once `OrtRuntimeAvailability.isAvailable` (a runtime `dlopen` check) is
// true — see that type's doc comment — so a machine without
// `libonnxruntime.so.1` installed never executes any of this file's ORT
// calls, even though they're always compiled in.
import COnnxRuntime
import Dispatch
import Foundation

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

  private var env: OpaquePointer?
  private var loadedSessions: OrtSessionSet?
  private var idleReleaseWorkItem: DispatchWorkItem?

  private init() {}

  /// Runs `body`, asserting it is already executing on `queue` — NOT a
  /// `queue.sync` hop (see P8-B fix below for why that was a real, live
  /// bug, not a style choice).
  ///
  /// `tier` is part of the cache key (see `loadedSessionsOrCreate`)
  /// because it determines `intra_op_num_threads` and whether the
  /// orientation session is even loaded — a tier change (e.g. the user
  /// unplugs a laptop mid-session, changing `MachineCapacity.onBattery`)
  /// must rebuild sessions with the new tier's settings, not silently
  /// keep running the old tier's thread count forever. Returns `nil`
  /// whenever session creation fails for any reason — including ONNX
  /// Runtime not being loadable at all (`OrtSessionSet.create`'s own
  /// `loadApi()` call degrades to `nil` in that case; callers are expected
  /// to have already checked `OrtRuntimeAvailability.isAvailable` before
  /// ever reaching here, per `OnnxTextRecognizer.recognizeText`).
  ///
  /// P8-B FIX (found via this task's own real, end-to-end Docker
  /// verification — the first time this code path ever actually ran
  /// against a real ONNX Runtime, since it previously compiled to nothing
  /// behind the never-defined `CLIPNEST_HAS_ONNXRUNTIME` flag): this used
  /// to be `queue.sync { dispatchPrecondition(...); ... }`. That is a
  /// SELF-DEADLOCK given this type's ONLY real call site
  /// (`OCRPipeline.run`, whose own doc comment already says "MUST be
  /// called from `OrtEnvironment.shared.queue`") — `OCRRequestQueue`
  /// dispatches its `work` closure onto this exact `queue` and runs
  /// `OCRPipeline.run` (hence `withSessions`) FROM INSIDE that closure, so
  /// a `queue.sync` here is a serial queue synchronously waiting on
  /// itself. `libdispatch` detects exactly this pattern and traps
  /// (`__DISPATCH_WAIT_FOR_QUEUE__`) rather than hanging forever — this
  /// reproduced 100% of the time, real crash, not a hang, confirmed via a
  /// real recognition attempt in this task's verification container (see
  /// `.claude/logs/senior-dev.md`, P8-B). Since the caller already
  /// guarantees "on `queue`," the correct fix is to assert that (matching
  /// `OCRPipeline.run`'s own `dispatchPrecondition`-only self-check) and
  /// call `body` directly — no second hop needed or safe.
  func withSessions<Result>(
    modelPaths: OCRModelPaths, tier: OCRTierConfiguration, _ body: (OrtSessionSet) -> Result
  ) -> Result? {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let sessions = loadedSessionsOrCreate(modelPaths: modelPaths, tier: tier) else {
      return nil
    }
    scheduleIdleRelease()
    return body(sessions)
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
    loadedSessions = nil  // `OrtSessionSet.deinit` releases the native handles.
  }
}
