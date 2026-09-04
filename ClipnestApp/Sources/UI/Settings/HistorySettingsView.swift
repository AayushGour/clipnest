// HistorySettingsView.swift
//
// The History settings tab: choose how much history to keep (maps directly to
// SettingsStore.retentionCap -> ClipStore.enforceRetention) and clear it all.
// Pinned items are always kept, regardless of the cap. Retention derivation is
// unit-tested in SettingsStoreTests; this view is pure binding + a confirm.
//
// T-OCR2: also hosts the "Recognize text in copied images" toggle
// (SettingsStore.isTextRecognitionEnabled, default OFF) — on-device OCR run
// by ClipboardMonitor at capture time only (never idle-scan/background
// sweep). The helper text is deliberately explicit that recognized text
// becomes searchable, including anything sensitive a screenshot happened to
// show — this is a real privacy trade-off (pixels a user only ever
// intended visually become indexed text), which is exactly why the default
// is OFF rather than on.
//
// T-OCR8: directly under that toggle, a Fast/Accurate quality Picker
// (SettingsStore.textRecognitionQuality, default Accurate) — disabled
// (not hidden) while the toggle is off, so it's discoverable and its
// default is visible even before a user opts into OCR at all, without a
// layout jump when they do. Existing rows already recognized at the old
// quality are NOT re-recognized when this changes — same "no retroactive
// re-processing" scope as the toggle itself; only future copies pick up a
// changed quality.
//
// T-UX1: also hosts "Recognize Text in Existing Images" — a one-off
// backfill over already-captured images that have no recognized text yet.
// Deliberately independent of the toggle above ("the user can choose when
// to run OCR," per the routed request): this button works whether or not
// "Recognize text in copied images" is on, and running it never flips that
// toggle. It reuses whatever quality the picker above is currently set to
// — the same value a fresh capture would use — but that's the only thing
// it reads from `settings`; all the run/progress/cancel state lives in
// `OCRBackfillViewModel` (owned by `AppEnvironment`, injected here), not in
// this view, matching coding-standards.md's "UI kept thin" rule.

import ClipnestCore
import SwiftUI

struct HistorySettingsView: View {
  @Bindable var settings: SettingsStore
  let clipStore: any ClipStore
  let ocrBackfillViewModel: OCRBackfillViewModel

  @State private var showClearConfirm = false
  @State private var clearError: String?

  init(
    settings: SettingsStore, clipStore: any ClipStore, ocrBackfillViewModel: OCRBackfillViewModel
  ) {
    self.settings = settings
    self.clipStore = clipStore
    self.ocrBackfillViewModel = ocrBackfillViewModel
  }

  var body: some View {
    Form {
      Picker("Keep history for", selection: $settings.retentionMode) {
        Text("Everything").tag(SettingsStore.RetentionMode.unlimited)
        Text("Most recent items").tag(SettingsStore.RetentionMode.items)
        Text("A number of days").tag(SettingsStore.RetentionMode.days)
      }

      switch settings.retentionMode {
      case .unlimited:
        EmptyView()
      case .items:
        Stepper(
          "Keep \(settings.retentionItemCount) items",
          value: $settings.retentionItemCount,
          in: 10...100_000,
          step: 50
        )
      case .days:
        Stepper(
          "Keep \(settings.retentionDays) days",
          value: $settings.retentionDays,
          in: 1...365,
          step: 1
        )
      }

      Text("Pinned items are always kept.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle("Recognize text in copied images", isOn: $settings.isTextRecognitionEnabled)

      // T-OCR8: visually subordinate to the toggle above (indented, right
      // beneath it, disabled rather than hidden while OCR is off) — it only
      // matters once recognition is actually running. Disabled rather than
      // hidden: hiding would shift every control below it on every toggle
      // flip, and a user deciding whether to turn OCR on at all can't see
      // that Accurate is already the default until they've already opted
      // in. A disabled row costs nothing and answers "what will happen"
      // before the toggle is ever flipped.
      Picker("Recognition quality", selection: $settings.textRecognitionQuality) {
        Text("Fast").tag(TextRecognitionQuality.fast)
        Text("Accurate").tag(TextRecognitionQuality.accurate)
      }
      .padding(.leading, 20)
      .disabled(!settings.isTextRecognitionEnabled)
      Text(
        "Accurate (recommended) reads punctuation, digits, and arrows correctly but takes "
          + "longer per screenshot. Fast is quicker but can confuse similar characters, like "
          + "1 and l. Neither can read keyboard symbols such as ⌘ ⌥ ⇧."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.leading, 20)

      Text(
        "Lets you search screenshots by their contents. Runs on-device when you copy an image "
          + "— nothing is uploaded or shared. Off by default: only enable this if you're "
          + "comfortable with screenshots' visible text becoming searchable, including anything "
          + "sensitive shown on screen at the time."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      ocrBackfillRow

      Section {
        Button("Clear All History…", role: .destructive) {
          showClearConfirm = true
        }
        if let clearError {
          Text(clearError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    // T-UX1: loads the initial "N images have no recognized text" count
    // once, when the tab first appears — `OCRBackfillViewModel` itself
    // refreshes it again after a run finishes, so this view never needs to
    // re-trigger that.
    .task {
      await ocrBackfillViewModel.refreshPendingCount()
    }
    .confirmationDialog(
      "Clear all clipboard history?",
      isPresented: $showClearConfirm,
      titleVisibility: .visible
    ) {
      Button("Clear All History", role: .destructive) {
        let store = clipStore
        Task {
          do {
            try await store.clearHistory()
            clearError = nil
          } catch {
            clearError = error.localizedDescription
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This permanently deletes every captured item, including pinned ones. "
          + "This can't be undone.")
    }
  }

  // MARK: - T-UX1: "Recognize Text in Existing Images"

  /// Three mutually-exclusive states, in priority order: a run currently in
  /// progress (progress text + Cancel); nothing in progress but a previous
  /// run just finished (a one-line result, shown above whatever's next);
  /// and the current pending count — either the Run button, or, if there's
  /// truly nothing to do, a plain statement instead of a button that would
  /// only ever no-op (this task's explicit brief).
  @ViewBuilder
  private var ocrBackfillRow: some View {
    if ocrBackfillViewModel.isRunning {
      if let progress = ocrBackfillViewModel.progress {
        Text("Recognizing images… \(progress.completed) of \(progress.total)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Cancel") {
        ocrBackfillViewModel.cancel()
      }
    } else {
      if let summary = ocrBackfillViewModel.lastSummary {
        Text(Self.finishedSummaryText(summary))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      switch ocrBackfillViewModel.pendingCount {
      case nil:
        EmptyView()
      case 0:
        Text("All images already have recognized text.")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .some(let count):
        Text(Self.pendingCountText(count))
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Recognize Text in Existing Images") {
          ocrBackfillViewModel.start(quality: settings.textRecognitionQuality)
        }
      }
    }
  }

  private static func pendingCountText(_ count: Int) -> String {
    count == 1 ? "1 image has no recognized text." : "\(count) images have no recognized text."
  }

  private static func finishedSummaryText(_ summary: OCRBackfillSummary) -> String {
    let verb = summary.wasCancelled ? "Cancelled" : "Done"
    return "\(verb) — recognized text in \(summary.progress.recognized) of "
      + "\(summary.progress.total) image(s)."
  }
}
