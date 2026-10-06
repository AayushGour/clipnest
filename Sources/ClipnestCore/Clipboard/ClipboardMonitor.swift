import Foundation

/// Abstraction over "what app is currently frontmost," used to attribute a
/// captured clip to its source app and to feed `PrivacyFilter.shouldCapture`'s
/// `sourceBundleID` check.
///
/// Deliberately separate from `Paste/FrontmostAppTracker` (plan task T14), which
/// records the frontmost app at a different point in time — right before the
/// picker opens — for a different purpose (paste targeting).
public protocol FrontmostApplicationProviding: Sendable {
  var frontmostBundleID: String? { get }
  var frontmostAppName: String? { get }
}

/// P2-A (Linux port): the production `NSWorkspace`-backed conformance
/// (formerly `WorkspaceFrontmostApplicationProvider`, defined here) moved to
/// `Platform/macOS/MacFrontmostApplicationProvider.swift` as
/// `MacFrontmostApplicationProvider`, wrapped in `#if os(macOS)` — this file
/// no longer imports `AppKit`. No call site referenced the old type by name
/// (verified — only this file's own default argument did), so the rename is
/// a pure extraction, not a behavior or public-API-surface change for any
/// existing caller.

/// Combines pasteboard-content reading (`PasteboardReading`) with change-count
/// polling, so a single injected value — `NSPasteboard.general` in production, a
/// fake in tests — can serve both roles for `ClipboardMonitor`.
public protocol MonitoredPasteboard: PasteboardReading {
  var changeCount: Int { get }
}

/// P2-A (Linux port): `extension NSPasteboard: MonitoredPasteboard {}`
/// moved verbatim to `Platform/macOS/NSPasteboard+Clipnest.swift`, wrapped
/// in `#if os(macOS)`.

/// Abstraction over `ClipboardMonitor.start()`'s previous direct
/// `Timer.scheduledTimer` call — extracted for the Linux port (P2-A),
/// since a repeating `Timer` needs a live `RunLoop` that a GTK main loop
/// will not provide. `start()` itself is unchanged behaviorally on macOS:
/// its default `pollScheduler` (`PlatformDefaults.pollScheduler`, resolving
/// to `MacTimerPollScheduler`) wraps the exact same `Timer.scheduledTimer`
/// call this protocol replaced — see that type's doc comment.
///
/// A conforming type is not required to guard against a redundant
/// `schedule` call while already scheduled — `ClipboardMonitor.start()`
/// owns that idempotency itself (`isPolling`), the same way it always has.
public protocol PollScheduling: Sendable {
  /// Begins calling `tick` repeatedly, roughly every `interval` seconds,
  /// until `cancel()` is called.
  func schedule(interval: TimeInterval, tick: @escaping @Sendable () -> Void)

  /// Stops any currently scheduled tick. Safe to call even when nothing is
  /// scheduled.
  func cancel()
}

/// Reports a `ClipStore` failure encountered while trying to store a capture.
///
/// `checkNow()` calls this instead of silently discarding the error (see
/// coding-standards.md: "do not swallow errors silently") so a real store
/// failure is distinguishable from "nothing to capture this cycle." Receives
/// only the thrown error — never the clipboard content that triggered it.
public typealias CaptureFailureHandler = @Sendable (Error) -> Void

/// Polls the pasteboard's `changeCount` for changes and, when one passes
/// `PrivacyFilter`, reads it via `PasteboardReader` and stores it via `ClipStore`.
///
/// Tests drive capture deterministically through `checkNow()` instead of waiting
/// on a real `Timer` — see `.claude/coding-standards.md`'s testing rules (no real
/// timers, no real key events in `ClipnestCoreTests`).
@MainActor
public final class ClipboardMonitor {
  /// Default poll interval, per the spec: macOS has no push notification for
  /// pasteboard changes, so ~0.4s balances responsiveness against CPU wake-ups.
  public static let defaultPollInterval: TimeInterval = 0.4

  /// P2-A (Linux port): was a raw `os.Logger`; now the platform-neutral
  /// `ClipnestLogger` shim (`Logging.swift`, added ahead of this task by
  /// P1-T5). `os.Logger`'s `privacy:` interpolation (`\(reason, privacy:
  /// .public)`) is an Apple-only API with no portable equivalent, so it's
  /// not carried over to the call site below — `ClipnestLogger.error(_:)`
  /// instead takes a plain `String` and applies `privacy: .public`
  /// internally, uniformly, for every message it logs (see its doc
  /// comment). That's the same privacy level this call site already used
  /// (`.public`, never `.private`), so behavior is unchanged; only the
  /// mechanism for it moved. Metadata-only discipline is unaffected either
  /// way: `reason` below is always a fixed case name or a bare type name,
  /// never clipboard content.
  private nonisolated static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "ClipboardMonitor")

  /// Default `CaptureFailureHandler`: logs metadata only (the error case name)
  /// — never the clipboard content that triggered the attempt.
  ///
  /// `nonisolated` + `public` because it's used as a default value on the
  /// `public` initializer below, which requires matching accessibility and no
  /// actor isolation (it touches no instance state, only the static `logger`).
  public nonisolated static func logCaptureFailure(_ error: Error) {
    let reason: String
    switch error {
    case let clipStoreError as ClipStoreError:
      switch clipStoreError {
      case .notFound: reason = "notFound"
      case .ioFailure: reason = "ioFailure"
      }
    case is BlobStoreError:
      reason = "blobIOFailure"
    default:
      reason = String(describing: type(of: error))
    }
    logger.error("ClipboardMonitor: failed to persist a captured item (\(reason))")
  }

  private let store: any ClipStore
  private let privacyFilter: PrivacyFilter
  private let reader: PasteboardReader
  private let blobStore: BlobStore
  private let pasteboard: any MonitoredPasteboard
  private let frontmostApplicationProvider: any FrontmostApplicationProviding
  private let pollInterval: TimeInterval
  private let excludedBundleIDsProvider: @Sendable () -> Set<String>
  /// T-OCR2: on-device text recognizer for freshly-captured `.image` items.
  /// `nil` in most existing tests/call sites (no recognition attempted) —
  /// production wiring (`AppEnvironment`) injects a real
  /// `VisionTextRecognizer`. Kept separate from `textRecognitionEnabledProvider`
  /// so a caller can wire the capability without also wiring a live user
  /// setting (e.g. tests that want recognition unconditionally attempted).
  private let textRecognizer: (any TextRecognizing)?
  /// Returns whether the *user* currently wants on-device text recognition
  /// on captured images (the persisted Settings "Recognize text in copied
  /// images" toggle, default OFF — see `SettingsStore
  /// .isTextRecognitionEnabled`). Read fresh at the moment each `.image` is
  /// captured, same "read fresh every cycle" shape as
  /// `captureEnabledProvider`. Defaults to always disabled so existing call
  /// sites/tests need no change and never accidentally start running Vision.
  private let textRecognitionEnabledProvider: @Sendable () -> Bool
  /// T-OCR8: returns the *user's* currently-selected recognition quality
  /// (the persisted Settings "Fast/Accurate" picker — see
  /// `SettingsStore.textRecognitionQuality`). Read fresh at the moment each
  /// `.image` recognition is scheduled — same "read fresh every cycle"
  /// shape as `textRecognitionEnabledProvider`/`captureEnabledProvider`, so
  /// changing the setting mid-session takes effect on the very next copy
  /// with no `ClipboardMonitor`/`VisionTextRecognizer` recreation. Defaults
  /// to always `.accurate`, matching `SettingsStore`'s default, so existing
  /// call sites/tests that don't care about quality still exercise the
  /// more-correct level.
  private let textRecognitionQualityProvider: @Sendable () -> TextRecognitionQuality
  /// Returns whether the *user* currently wants capture on (the persisted
  /// Settings "Pause capture" gate). Read fresh every `checkNow()` cycle and
  /// kept deliberately separate from the transient `isPaused` flag (which the
  /// snippet-expansion clipboard borrow toggles) — a transient `resume()` must
  /// never silently un-pause a user who paused in Settings. Defaults to always
  /// enabled so isolated tests and existing call sites need no change.
  private let captureEnabledProvider: @Sendable () -> Bool
  private let captureFailureHandler: CaptureFailureHandler
  /// P2-A (Linux port): see `PollScheduling`'s doc comment. Defaults to
  /// `PlatformDefaults.pollScheduler` — `MacTimerPollScheduler`
  /// (`Timer`-backed) on macOS.
  private let pollScheduler: any PollScheduling

  /// Whether `start()` has scheduled a repeating tick that hasn't since
  /// been `stop()`ped. Formerly this was inferred from `timer == nil`;
  /// `ClipboardMonitor` (not `PollScheduling`) owns this idempotency check,
  /// same as before — see `PollScheduling`'s doc comment.
  private var isPolling = false

  /// Whether `startEventDriven()` was used instead of `start()` — see its
  /// doc comment. Purely an introspectable marker; `checkNow()`'s own
  /// behavior never depends on it.
  public private(set) var isEventDriven = false

  private var lastChangeCount: Int

  /// A pasteboard `changeCount` that Clipnest itself produced (via
  /// `ignore(changeCount:)`) and that `checkNow()` should treat as
  /// already-seen instead of a new external copy. `nil` when nothing is
  /// pending. See `ignore(changeCount:)`'s doc comment.
  ///
  /// **T-HANG4 (residual self-paste race — down from 18/18 to a rare,
  /// load-dependent race after T-HANG2's fix):** the one remaining hop is
  /// in `Paster.paste` (`Sources/ClipnestCore/Paste/Paster.swift`, not this
  /// file) — `await onPasteboardWrite?(pasteboard.changeCount)`, which
  /// calls back into `ignore(changeCount:)` via
  /// `PickerViewModel+Paste.performPaste`'s closure. That `await`, on a
  /// value of a `@MainActor`-isolated function type, elides its executor
  /// hop and runs synchronously whenever the Swift runtime can prove the
  /// caller is already on `MainActor`'s executor (the common case here,
  /// since `paste()` is entered from an already-`@MainActor`-isolated
  /// caller) — but that elision is a runtime optimization, not a language
  /// guarantee; under contention it can still suspend and re-enqueue as a
  /// fresh job on `MainActor`'s serial queue, where it can land BEHIND an
  /// already-queued `checkNow()` tick from the 0.4s poll `Timer`. If that
  /// happens, `checkNow()` reads the new `changeCount` before `ignore(...)`
  /// has registered it. Confirmed real and reproducible with a standalone
  /// harness mirroring `tools/stress-harness`'s `SelfPasteRaceScenario`
  /// (11/780 trials raced, all at a single narrow offset — see this task's
  /// report) — genuinely rare, and outside this file's edit boundary to
  /// close at the source. What IS closeable here, and implemented below:
  /// `checkNow()` re-checks `ignoredChangeCount` a second time, immediately
  /// before the store write that would otherwise create the duplicate row
  /// — see that check's own doc comment for why this reliably narrows (not
  /// eliminates) the window: it gives a same-cycle `ignore(...)` call the
  /// FULL duration of `checkNow()`'s own off-main hops (`classify`'s
  /// `Task.detached`, at minimum) to land, not just the single hop above.
  private var ignoredChangeCount: Int?

  /// T-HANG5: `Task` handle for a capture-time text-recognition job
  /// currently scheduled or in flight, keyed by the `ClipItem.id` it
  /// targets. Lets a caller that knows an item's row is gone (deleted, or
  /// `clearHistory()`) cancel that item's still-pending recognition instead
  /// of letting it run Vision + a doomed `store.setRecognizedText` write to
  /// completion — the capture-time analogue of `OCRBackfillCoordinator
  /// .run`'s own cooperative-cancellation model (see that type's doc
  /// comment; this file does not edit it, per this task's boundary).
  ///
  /// **Known limitation (T-HANG5):** nothing in this file calls
  /// `cancelPendingRecognition(for:)`/`cancelAllPendingRecognition()` yet.
  /// `ClipboardMonitor` has no visibility into deletions or `clearHistory()`
  /// today — `PickerViewModel.delete(_:)` and `HistorySettingsView`'s
  /// "Clear All History…" action call `ClipStore.delete`/`clearHistory`
  /// directly, never through this monitor (confirmed by inspection: no
  /// call site outside this file references either method). Wiring one of
  /// those call sites to invoke a method below is required to actually
  /// close the gap, and both files (`PickerViewModel.swift`,
  /// `HistorySettingsView.swift`) are outside this task's edit boundary —
  /// see this task's report for the exact wiring a full fix would add.
  /// Even once wired, cancellation here is best-effort, not a guarantee:
  /// it only pre-empts a job that hasn't yet reached (or resumed past) the
  /// `Task.isCancelled` checks around `recognizer.recognizeText(in:quality:)`
  /// in `scheduleTextRecognition` below — once Vision is actually running
  /// (inside `VisionTextRecognizer`'s own serial `recognitionQueue`, also
  /// outside this file), cancelling the wrapping `Task` cannot interrupt it
  /// mid-recognition, mirroring `OCRBackfillCoordinator`'s own "never
  /// mid-item" cancellation contract. Until wired, today's existing
  /// outcome stands unchanged: an already-running job that outlives its
  /// target row fails harmlessly at the `store.setRecognizedText` write
  /// (`.notFound`, routed through `captureFailureHandler` — see T-OCR6)
  /// with no ghost row created, exactly as verified at 100-image scale
  /// before this change.
  ///
  /// If two recognition jobs are ever in flight for the same item id at
  /// once (see `ClipboardMonitorTests
  /// .recognitionHandlesConcurrentDuplicateCopiesBeforeFirstPassCompletes`
  /// for when that happens), this dictionary tracks only the most recently
  /// scheduled job for that id — an earlier job's own completion (success
  /// or failure) then removes whichever entry is CURRENTLY stored for that
  /// id, which may by then be the newer job's, not its own. Never a
  /// correctness issue (every job still independently completes-or-fails
  /// safely on its own, per `scheduleTextRecognition`'s existing resilience
  /// contract, and a stale removal only ever makes a future
  /// `cancelPendingRecognition(for:)` call a no-op, never cancels the wrong
  /// job) — just a note that cancellation coverage in that edge case is
  /// partial, consistent with this feature's overall best-effort nature.
  private var pendingRecognitionTasks: [UUID: Task<Void, Never>] = [:]

  /// Whether capture is currently paused. Honored by `checkNow()`; wired to
  /// UI (menu + Settings) in plan task T31.
  public private(set) var isPaused = false

  /// Called on `@MainActor` right after `checkNow()` successfully stores a
  /// captured item — a fresh insert or a dedup bump (see
  /// `insertOrBumpDuplicate`'s doc comment; a bump also updates `createdAt`
  /// to now, so it belongs at the top of History again too). Lets the
  /// composition root (`AppEnvironment`, which owns both this monitor and
  /// `PickerViewModel`) push a live update into the picker instead of the
  /// picker polling `ClipStore` on a timer (plan task T50/T51 — see
  /// `PickerViewModel`'s doc comment). Defaults to a no-op so this type
  /// stays usable without a listener (e.g. in isolated tests). Not
  /// `@Sendable`/optional-closure-crossing-actors: `ClipboardMonitor` is
  /// itself `@MainActor`, so a plain stored closure is safe here, mirroring
  /// `PickerViewModel.dismiss`/`suppressOwnPasteboardWrite`'s identical
  /// "settable after construction, defaults to a no-op" shape.
  public var onCapture: (ClipItem) -> Void = { _ in }

  public init(
    store: any ClipStore,
    privacyFilter: PrivacyFilter = PrivacyFilter(),
    reader: PasteboardReader = PasteboardReader(),
    blobStore: BlobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory()),
    pasteboard: any MonitoredPasteboard = PlatformDefaults.monitoredPasteboard,
    frontmostApplicationProvider: any FrontmostApplicationProviding =
      PlatformDefaults.frontmostApplicationProvider,
    pollInterval: TimeInterval = ClipboardMonitor.defaultPollInterval,
    pollScheduler: any PollScheduling = PlatformDefaults.pollScheduler,
    excludedBundleIDsProvider: @escaping @Sendable () -> Set<String> = { [] },
    captureEnabledProvider: @escaping @Sendable () -> Bool = { true },
    textRecognizer: (any TextRecognizing)? = nil,
    textRecognitionEnabledProvider: @escaping @Sendable () -> Bool = { false },
    textRecognitionQualityProvider: @escaping @Sendable () -> TextRecognitionQuality = {
      .accurate
    },
    captureFailureHandler: @escaping CaptureFailureHandler = ClipboardMonitor.logCaptureFailure
  ) {
    self.store = store
    self.privacyFilter = privacyFilter
    self.reader = reader
    self.blobStore = blobStore
    self.pasteboard = pasteboard
    self.frontmostApplicationProvider = frontmostApplicationProvider
    self.pollInterval = pollInterval
    self.pollScheduler = pollScheduler
    self.excludedBundleIDsProvider = excludedBundleIDsProvider
    self.captureEnabledProvider = captureEnabledProvider
    self.textRecognizer = textRecognizer
    self.textRecognitionEnabledProvider = textRecognitionEnabledProvider
    self.textRecognitionQualityProvider = textRecognitionQualityProvider
    self.captureFailureHandler = captureFailureHandler
    lastChangeCount = pasteboard.changeCount
  }

  /// Starts polling via `pollScheduler` (a repeating `Timer` on macOS, via
  /// `MacTimerPollScheduler` — see `PollScheduling`'s doc comment). No-op if
  /// already started. Behavior is byte-identical to before P2-A's
  /// extraction: same `weak self` capture, same hop to `Task { @MainActor
  /// in ... }` before calling `checkNow()` — only the raw
  /// `Timer.scheduledTimer` call itself moved into `pollScheduler`.
  public func start() {
    guard !isPolling else { return }
    isPolling = true
    pollScheduler.schedule(interval: pollInterval) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        _ = await self.checkNow()
      }
    }
  }

  /// Stops polling (if `start()` was used) and/or clears the
  /// `startEventDriven()` marker. Safe to call even if neither was started.
  public func stop() {
    isEventDriven = false
    guard isPolling else { return }
    isPolling = false
    pollScheduler.cancel()
  }

  /// Starts the monitor in event-driven mode: `pollScheduler` is never
  /// touched (no `Timer`/`PollScheduling` scheduling of any kind) — the
  /// platform backend (e.g. a Linux X11/Wayland selection-owner listener,
  /// or a future GNOME Shell extension) is responsible for calling
  /// `checkNow()` directly whenever it observes a real clipboard-ownership
  /// change. `checkNow()` itself needs no changes to support this — it has
  /// never depended on `start()`/`pollScheduler` at all, only on being
  /// called.
  ///
  /// Stops any active `start()`-driven polling first, so a caller can
  /// switch from one mode to the other without both a `Timer` tick and an
  /// external event both driving `checkNow()` at once (harmless either way
  /// — `checkNow()`'s `changeCount` check makes a redundant call a no-op —
  /// but avoiding it keeps behavior easier to reason about).
  ///
  /// Purely additive: `start()`'s own polling behavior above is completely
  /// unaffected by this method's existence, per this task's directive.
  public func startEventDriven() {
    if isPolling {
      isPolling = false
      pollScheduler.cancel()
    }
    isEventDriven = true
  }

  /// Pauses capture. `checkNow()` still advances `lastChangeCount` so that
  /// resuming doesn't immediately re-capture whatever changed while paused.
  public func pause() {
    isPaused = true
  }

  /// Resumes capture after `pause()`.
  public func resume() {
    isPaused = false
  }

  /// Tells the monitor that `changeCount` is the result of a pasteboard
  /// write Clipnest itself performed — a copy-on-select in the picker
  /// (plan task T12), or a future synthesized paste (`Paster`, plan task
  /// T15/T16) — not a real external copy. Any caller that writes to the
  /// pasteboard Clipnest itself owns should call this immediately after,
  /// with the pasteboard's resulting `changeCount`.
  ///
  /// The next `checkNow()` that observes exactly this `changeCount` treats
  /// it as already-seen: `lastChangeCount` still advances past it (so it's
  /// never re-evaluated), but nothing is classified or stored. A change to
  /// any *other* `changeCount` (a real external copy) is unaffected.
  ///
  /// Only one ignored `changeCount` is tracked at a time — a later call
  /// before the pending one is consumed overwrites it, mirroring
  /// `FrontmostAppTracker`'s "last-recorded wins" semantics.
  public func ignore(changeCount: Int) {
    ignoredChangeCount = changeCount
  }

  /// T-HANG5: cancels the capture-time recognition job for `id`, if one is
  /// still pending, and removes its tracking entry. No-op if none is
  /// pending — safe to call unconditionally (e.g. right after a delete,
  /// regardless of whether that item ever had OCR scheduled). See
  /// `pendingRecognitionTasks`'s doc comment for what this can and cannot
  /// pre-empt, and for the caller-side wiring still needed for this to run
  /// in production (outside this task's edit boundary).
  public func cancelPendingRecognition(for id: UUID) {
    pendingRecognitionTasks.removeValue(forKey: id)?.cancel()
  }

  /// T-HANG5: cancels every currently-pending capture-time recognition job
  /// — the "Clear All History…" analogue of `cancelPendingRecognition(for:)`
  /// above, since a full `clearHistory()` invalidates every row at once.
  public func cancelAllPendingRecognition() {
    let tasks = pendingRecognitionTasks.values
    pendingRecognitionTasks.removeAll()
    for task in tasks { task.cancel() }
  }

  /// Performs one check-and-capture cycle synchronously with respect to test
  /// control flow: reads the pasteboard's current `changeCount`, and if it
  /// differs from the last observed value, classifies and (if accepted by
  /// `PrivacyFilter`) stores the content. Returns the resulting stored item,
  /// or `nil` if nothing was captured this cycle.
  @discardableResult
  public func checkNow() async -> ClipItem? {
    let currentChangeCount = pasteboard.changeCount
    guard currentChangeCount != lastChangeCount else { return nil }
    lastChangeCount = currentChangeCount

    if ignoredChangeCount == currentChangeCount {
      ignoredChangeCount = nil
      return nil
    }

    let sourceBundleID = frontmostApplicationProvider.frontmostBundleID
    let sourceAppName = frontmostApplicationProvider.frontmostAppName

    guard
      privacyFilter.shouldCapture(
        availableTypes: pasteboard.availableTypes,
        sourceBundleID: sourceBundleID,
        isPaused: isPaused || !captureEnabledProvider(),
        customExcludedBundleIDs: excludedBundleIDsProvider()
      )
    else {
      return nil
    }

    // T-PERF1: `pullRawPayload` does the real `NSPasteboard` reads (types,
    // `data(forType:)`/`string(forType:)`) and MUST stay here on
    // `@MainActor` — that's genuine AppKit pasteboard access, which per this
    // task's directive is the one thing that stays main-isolated. Everything
    // downstream of it — `classify`'s SHA-256 hashing and `previewText`
    // construction, pure CPU work with no further pasteboard access — moves
    // to a detached background task, same `Task.detached(priority: .utility)`
    // pattern the blob write just below already uses. `reader` is `Sendable`
    // (stateless struct) so it's safe to copy into the closure; `rawPayload`
    // is `Sendable` by construction (`PasteboardReader.RawPayload`).
    guard let rawPayload = reader.pullRawPayload(from: pasteboard) else { return nil }
    let reader = self.reader
    let classified = await Task.detached(priority: .utility) {
      reader.classify(rawPayload)
    }.value
    // T-PF2: `classify` can now return `nil` for an image that exceeds
    // `PasteboardReader.maxCapturedImageByteSize`/`maxCapturedImagePixelDimension`
    // (see its doc comment) — same "nothing to capture this cycle" outcome
    // as `pullRawPayload` returning `nil` just above, not a failure worth
    // routing through `captureFailureHandler`.
    guard let result = classified else { return nil }

    let blobPath: String?
    do {
      if let rawData = result.rawData {
        // Off the main actor: `BlobStore` is `Sendable` and `write(_:)` is
        // pure filesystem I/O, so a large payload's disk write can't block
        // the UI here — same `Task.detached(priority: .utility)` pattern
        // already used for off-main blob reads (`ItemPreview.AsyncBlobImage`,
        // `ItemRow.load()`). Copied into a local `let` first so the closure
        // captures the `Sendable` `BlobStore` value, not `self`.
        let blobStore = self.blobStore
        blobPath = try await Task.detached(priority: .utility) {
          try blobStore.write(rawData)
        }.value
      } else {
        blobPath = nil
      }
    } catch {
      // A blob write failure means this capture cannot be safely stored
      // (a dangling blobPath is worse than not capturing this cycle) — same
      // "surface, don't swallow" pattern as a `ClipStore` failure below.
      captureFailureHandler(error)
      return nil
    }

    // T-HANG4: re-check `ignoredChangeCount` a second time, right before the
    // one step that actually creates/bumps a persisted row — not just once,
    // at this method's very top. Everything between that first check and
    // here (`classify`'s `Task.detached` hop above, at minimum, plus the
    // blob write's own hop when one runs) gives a same-cycle
    // `Paster.paste` real wall-clock time to report its write via
    // `onPasteboardWrite` and call `ignore(changeCount:)` — see
    // `ignoredChangeCount`'s doc comment (T-HANG4) for the exact hop this
    // is closing the tail of. Same semantics as the early check: bail out
    // with nothing stored, no `onCapture`, no OCR scheduling — nothing has
    // been persisted to `store` yet, only (possibly) a blob written above.
    //
    // That blob is deliberately NOT deleted here. `BlobStore` is content-
    // addressed with NO reference counting: `write(_:)` returns an
    // EXISTING file's path unchanged whenever those bytes are already on
    // disk. This bail fires on a self-paste race, where the bytes are by
    // construction an existing history item's own content round-tripped
    // through the pasteboard — for `.richText`, `Paster.writeRichText` and
    // `PasteboardReader.readRichText` preserve the stored RTF byte-for-byte
    // — so `blobPath` here is very often the SAME path a live, visible item
    // still references. Deleting it corrupts that unrelated item (its next
    // blob read throws `.notFound`), trading a harmless duplicate row for
    // real data loss. Not deleting costs nothing: if the bytes were already
    // present no new file was created, and if they weren't, the next
    // capture of the same content reuses this exact blob.
    if ignoredChangeCount == currentChangeCount {
      ignoredChangeCount = nil
      return nil
    }

    // Only `.file` classifications ever carry `fileURL` — gated explicitly
    // (not just relying on `result.fileURL` being nil for other kinds) so
    // `.image`/`.text`/`.link`/`.richText` items are never affected by this.
    let fileReference: String? = result.kind == .file ? result.fileURL?.absoluteString : nil

    let item = ClipItem(
      kind: result.kind,
      previewText: result.previewText,
      contentHash: result.contentHash,
      sourceAppName: sourceAppName,
      sourceBundleID: sourceBundleID,
      byteSize: result.byteSize,
      blobPath: blobPath,
      fileReference: fileReference
    )

    do {
      let stored = try await store.insertOrBumpDuplicate(item)
      onCapture(stored)

      // T-OCR2: on-device text recognition runs ONLY here, on copy — never
      // at idle-scan or on a background sweep (that's the approved design).
      // Gated on all four: the user setting, `.image` kind, no `ocrText`
      // yet (a re-copied duplicate returned by `insertOrBumpDuplicate`
      // already has its text from the first capture — never re-run
      // recognition on content that's already been recognized), and raw
      // image bytes actually being available. Fired off via
      // `scheduleTextRecognition`, NOT awaited — `checkNow()` must return
      // exactly as fast as it does today regardless of this setting.
      if textRecognitionEnabledProvider(), stored.kind == .image, stored.ocrText == nil,
        let recognizer = textRecognizer, let rawData = result.rawData
      {
        // T-OCR8: quality is also read fresh here, at schedule time —
        // same freshness guarantee as the `textRecognitionEnabledProvider()`
        // read just above, so a mid-session Fast<->Accurate change takes
        // effect on this very capture, not the next `ClipboardMonitor`.
        let quality = textRecognitionQualityProvider()
        scheduleTextRecognition(
          for: stored, imageData: rawData, recognizer: recognizer, quality: quality)
      }

      return stored
    } catch {
      // Surface the failure (metadata-only) instead of silently returning nil
      // for both "nothing to capture" and "the store failed" — see
      // coding-standards.md's error-handling rule.
      captureFailureHandler(error)
      return nil
    }
  }

  /// T-OCR2: runs `recognizer` against `imageData`, at the `quality` the
  /// caller already resolved (T-OCR8 — passed through as a plain value, not
  /// re-read here, so this method carries no provider dependency of its
  /// own), off the main actor (a detached `.utility` task, same priority
  /// `checkNow()`'s own blob write uses). Persists any recognized text via
  /// `store.setRecognizedText`, and — only on success — hops back to
  /// `@MainActor` to notify listeners via
  /// the exact same `onCapture` hook a fresh capture uses, so the picker's
  /// existing capture→requery wiring (`AppEnvironment`'s `monitor.onCapture`
  /// → `PickerViewModel.handleNewCapture()`) picks up the now-searchable/
  /// badge-worthy item with no second notification path to maintain.
  ///
  /// Deliberately fire-and-forget from `checkNow()`'s perspective: this
  /// method itself returns immediately (it only *schedules* the detached
  /// task), so capture latency is unaffected regardless of how long
  /// recognition takes. Every failure — recognition finding nothing,
  /// recognition failing, or the store write failing — is routed through
  /// `captureFailureHandler` (T-OCR6 — previously the store-write failure
  /// went straight to the static `Self.logCaptureFailure`, unlike every
  /// other failure path in this file, which made it untestable and
  /// unable to honor an injected handler) rather than surfaced as a
  /// capture failure, since the item itself was already captured
  /// successfully before this runs.
  ///
  /// T-HANG5: tracks its own `Task` in `pendingRecognitionTasks`, keyed by
  /// `item.id`, for the lifetime of the job (removed on every exit path —
  /// success, "nothing recognized," or a store-write failure), and checks
  /// `Task.isCancelled` both before starting recognition and again before
  /// persisting its result, so a caller with a handle to this monitor CAN
  /// cancel a still-pending job via `cancelPendingRecognition(for:)`/
  /// `cancelAllPendingRecognition()` — see `pendingRecognitionTasks`'s doc
  /// comment for what's wired today vs. what a full fix still needs.
  private func scheduleTextRecognition(
    for item: ClipItem, imageData: Data, recognizer: any TextRecognizing,
    quality: TextRecognitionQuality
  ) {
    let store = self.store
    let captureFailureHandler = self.captureFailureHandler
    let itemID = item.id
    let task = Task.detached(priority: .utility) { [weak self] in
      defer {
        Task { @MainActor [weak self] in
          self?.pendingRecognitionTasks.removeValue(forKey: itemID)
        }
      }

      guard !Task.isCancelled else { return }

      guard let text = await recognizer.recognizeText(in: imageData, quality: quality),
        !text.isEmpty
      else {
        return
      }

      guard !Task.isCancelled else { return }

      do {
        try await store.setRecognizedText(itemID, text: text)
      } catch {
        captureFailureHandler(error)
        return
      }
      guard let self else { return }
      await MainActor.run {
        var recognized = item
        recognized.ocrText = text
        self.onCapture(recognized)
      }
    }
    pendingRecognitionTasks[itemID] = task
  }
}
