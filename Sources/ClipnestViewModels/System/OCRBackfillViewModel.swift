// OCRBackfillViewModel.swift
//
// T-UX1: `@MainActor` state + orchestration for the History settings tab's
// "Recognize Text in Existing Images" action — the user-triggered, one-off
// pass over already-captured images that have no recognized text yet.
// Deliberately decoupled from `SettingsStore.isTextRecognitionEnabled`
// (the routed request's own words: "the user can choose when to run OCR"):
// this reads nothing from `SettingsStore` except the quality value handed
// to `start(quality:)` at the moment the button is pressed, and never
// writes to `SettingsStore` at all — running a backfill can never flip the
// at-capture toggle.
//
// The actual iterate-recognize-write work lives in `ClipnestCore
// .OCRBackfillCoordinator` (fully unit-tested there, off any actor); this
// type only adds the SwiftUI-observable state (`pendingCount`/`isRunning`/
// `progress`/`lastSummary`) and owns the one background `Task` a run
// executes in, so `HistorySettingsView` stays a thin binding layer like
// every other Settings tab (coding-standards.md: "UI kept thin by design").
//
// Never blocks the main actor: `start(quality:)` runs the coordinator's
// `run(...)` inside `Task.detached(priority: .utility)` — the same pattern
// `ClipboardMonitor.scheduleTextRecognition`/`checkNow()` already use for
// exactly this reason — and only ever touches `@MainActor` state via the
// `await MainActor.run { ... }` hops below, for the progress/result
// updates a SwiftUI view needs to observe. `OCRBackfillCoordinator.run(...)`
// itself further guarantees its own per-item blob read never runs
// synchronously on whichever actor calls it (see that method's doc
// comment) — so this type adds no main-actor risk of its own even before
// accounting for the outer `Task.detached` here.

import ClipnestCore
#if canImport(Darwin)
  import Observation
#endif

@MainActor
// P5 (Linux port): `Observation` IMPORTS on Linux but does NOT LINK -- Swift
// 6.0.3 and 6.1 on Ubuntu 22.04 both ship a libswiftObservation.so with an
// undefined reference to `swift::threading::fatal`. `canImport(Observation)`
// is therefore a misleading signal, so this gates on `canImport(Darwin)`
// instead. macOS keeps `@Observable` exactly as before (SwiftUI's Settings
// window depends on it); off Apple this is a plain class, which is all the
// GTK layer needs since it observes explicitly rather than via SwiftUI.
#if canImport(Darwin)
  @Observable
#endif
public final class OCRBackfillViewModel {
  private let coordinator: OCRBackfillCoordinator

  /// `nil` until the first `refreshPendingCount()` completes — lets the
  /// view show a neutral/loading state for one frame instead of flashing
  /// "0 images" before the real count is known.
  public private(set) var pendingCount: Int?
  public private(set) var isRunning = false
  public private(set) var progress: OCRBackfillProgress?
  public private(set) var lastSummary: OCRBackfillSummary?

  /// Not observed UI state (it's plumbing, not something a view renders
  /// directly) — `@ObservationIgnored` keeps it out of `@Observable`'s
  /// dependency tracking, same reasoning `SettingsStore.defaults` and
  /// `UpdateChecker.timer` already use for their own non-UI internals.
  #if canImport(Darwin)
    @ObservationIgnored private var runTask: Task<Void, Never>?
  #else
    private var runTask: Task<Void, Never>?
  #endif

  public init(coordinator: OCRBackfillCoordinator) {
    self.coordinator = coordinator
  }

  /// Recomputes `pendingCount` — called when the History tab appears, and
  /// again automatically once a run finishes (the one other moment the
  /// count can change from under the view). Best-effort: a failure leaves
  /// `pendingCount` at whatever it was already showing, same
  /// "housekeeping, not a destructive action" precedent
  /// `HistorySettingsView`'s existing `clearError` handling sets for
  /// `clearHistory()`'s failure path.
  public func refreshPendingCount() async {
    pendingCount = try? await coordinator.pendingCount()
  }

  /// Starts a backfill run at `quality` — the caller's current
  /// `SettingsStore.textRecognitionQuality`, read once by the caller at
  /// the moment the button is pressed and passed through as a plain value,
  /// same "resolve once" shape `ClipboardMonitor.scheduleTextRecognition`
  /// already uses for a single capture's quality. No-op if a run is
  /// already in flight — `HistorySettingsView` swaps the button for
  /// Cancel while `isRunning`, so a second tap can't reach this, but the
  /// guard makes that safe even if it somehow did.
  public func start(quality: TextRecognitionQuality) {
    guard !isRunning else { return }
    isRunning = true
    progress = nil
    lastSummary = nil

    let coordinator = self.coordinator
    runTask = Task.detached(priority: .utility) { [weak self] in
      let summary = await coordinator.run(quality: quality) { progress in
        await MainActor.run { self?.progress = progress }
      }
      guard let self else { return }
      await MainActor.run {
        self.isRunning = false
        self.lastSummary = summary
        self.runTask = nil
      }
      await self.refreshPendingCount()
    }
  }

  /// Cancels an in-flight run. `OCRBackfillCoordinator.run(...)` still
  /// finishes whichever item is currently in progress (never mid-item —
  /// see its doc comment) before returning a summary with
  /// `wasCancelled == true`, which `start(quality:)`'s continuation above
  /// records as `lastSummary` exactly like a natural completion — so the
  /// finished-state UI needs no separate cancelled-vs-completed branch
  /// beyond reading `lastSummary.wasCancelled`.
  public func cancel() {
    runTask?.cancel()
  }
}
