// SettingsWindow+History.swift
//
// P7-D (Linux port, GTK4 view layer): the History settings tab — the GTK
// counterpart of macOS's `HistorySettingsView`. Retention mode/limits and
// on-device text recognition, all backed directly by `SettingsStore`. See
// `SettingsWindow+General.swift`'s doc comment for the `@MainActor`/
// `MainActor.assumeIsolated` split this file follows too.
//
// P10-A: also hosts the two other History-tab features macOS already ships
// that had no Linux call site — "Recognize Text in Existing Images" (the
// OCR backfill row, driven by `ocrBackfillViewModel`) and "Clear All
// History…" (a mandatory confirmation before `clipStore.clearHistory()` —
// this destroys every captured item, including pinned ones). See
// `SettingsWindow.swift`'s top doc comment for why the OCR row alone needs
// `pollOCRBackfillTick()`.
import CGtk4
import ClipnestCore
import ClipnestViewModels

extension SettingsWindow {
  @MainActor
  func buildHistoryTab() {
    let box = appendTab(title: "History")

    addRadioGroup(
      to: box,
      options: SettingsStore.RetentionMode.allCases.map { mode in
        (label: retentionModeLabel(mode), isInitiallyActive: mode == settings.retentionMode)
      }
    ) { [settings] selectedIndex in
      let mode = SettingsStore.RetentionMode.allCases[selectedIndex]
      MainActor.assumeIsolated {
        settings.retentionMode = mode
      }
    }

    addSpinButton(
      to: box, label: "Keep at most (items):",
      min: 1, max: Double(SettingsWindow.maxRetentionItemCount), step: 1,
      initialValue: Double(settings.retentionItemCount)
    ) { [settings] newValue in
      MainActor.assumeIsolated {
        settings.retentionItemCount = newValue
      }
    }

    addSpinButton(
      to: box, label: "Keep for (days):",
      min: 1, max: Double(SettingsWindow.maxRetentionDays), step: 1,
      initialValue: Double(settings.retentionDays)
    ) { [settings] newValue in
      MainActor.assumeIsolated {
        settings.retentionDays = newValue
      }
    }

    addCheckButton(
      to: box, label: "Recognize text in copied images",
      initialValue: settings.isTextRecognitionEnabled
    ) { [settings] isEnabled in
      MainActor.assumeIsolated {
        settings.isTextRecognitionEnabled = isEnabled
      }
    }

    addRadioGroup(
      to: box,
      options: TextRecognitionQuality.allCases.map { quality in
        (
          label: textRecognitionQualityLabel(quality),
          isInitiallyActive: quality == settings.textRecognitionQuality
        )
      }
    ) { [settings] selectedIndex in
      let quality = TextRecognitionQuality.allCases[selectedIndex]
      MainActor.assumeIsolated {
        settings.textRecognitionQuality = quality
      }
    }

    buildOCRBackfillRow(in: box)

    addButton(to: box, label: "Clear All History…") { [weak self] in
      MainActor.assumeIsolated {
        self?.confirmClearHistory()
      }
    }
    let clearHistoryErrorLabel = addErrorLabel(to: box)
    self.clearHistoryErrorLabel = clearHistoryErrorLabel
  }

  /// Upper bound offered by the "keep at most (items)" spin button — a UI
  /// ceiling, not a `ClipStore` limit (`RetentionCap.maxCount` accepts any
  /// positive `Int`); generous enough nobody needs a value above it.
  static let maxRetentionItemCount = 100_000
  /// Upper bound offered by the "keep for (days)" spin button — a UI
  /// ceiling, same reasoning as `maxRetentionItemCount` (roughly 10 years).
  static let maxRetentionDays = 3_650

  private func retentionModeLabel(_ mode: SettingsStore.RetentionMode) -> String {
    switch mode {
    case .unlimited: return "Keep everything"
    case .items: return "Limit by item count"
    case .days: return "Limit by age"
    }
  }

  private func textRecognitionQualityLabel(_ quality: TextRecognitionQuality) -> String {
    switch quality {
    case .fast: return "Fast"
    case .accurate: return "Accurate"
    }
  }

  // MARK: - P10-A: Clear All History

  /// Shows the mandatory confirmation before destroying every captured
  /// item (including pinned ones) — mirrors `HistorySettingsView`'s
  /// `.confirmationDialog(...)` exactly, GTK's `showConfirmationDialog(...)`
  /// counterpart (`SettingsWindow+Controls.swift`).
  @MainActor
  private func confirmClearHistory() {
    showConfirmationDialog(
      title: "Clear all clipboard history?",
      message:
        "This permanently deletes every captured item, including pinned ones. "
        + "This can't be undone.",
      confirmLabel: "Clear All History"
    ) { [weak self] in
      MainActor.assumeIsolated {
        self?.performClearHistory()
      }
    }
  }

  @MainActor
  private func performClearHistory() {
    let store = clipStore
    Task { @MainActor [weak self] in
      do {
        try await store.clearHistory()
        self?.showClearHistoryError(nil)
      } catch {
        self?.showClearHistoryError(String(describing: error))
      }
    }
  }

  @MainActor
  private func showClearHistoryError(_ message: String?) {
    guard let clearHistoryErrorLabel else { return }
    setStatusLabel(clearHistoryErrorLabel, text: message)
  }

  // MARK: - P10-A: "Recognize Text in Existing Images" (OCR backfill)

  /// Builds every widget the OCR backfill row needs, all initially hidden
  /// — `pollOCRBackfillTick()` (below) is the only thing that ever shows/
  /// updates them, reconciling against `ocrBackfillViewModel`'s actual
  /// state on every tick, the same "poll, don't push" shape `PickerWindow`
  /// itself used before its own push-based migration (see
  /// `SettingsWindow.swift`'s top doc comment for why this row alone still
  /// needs one).
  @MainActor
  private func buildOCRBackfillRow(in box: OpaquePointer) {
    let progressLabel = addStatusLabel(to: box)
    let progressBar = addProgressBar(to: box)
    let cancelButton = addButton(to: box, label: "Cancel") { [weak self] in
      MainActor.assumeIsolated {
        self?.ocrBackfillViewModel.cancel()
      }
    }
    let summaryLabel = addStatusLabel(to: box)
    let pendingLabel = addStatusLabel(to: box)
    let runButton = addButton(to: box, label: "Recognize Text in Existing Images") { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.ocrBackfillViewModel.start(quality: self.settings.textRecognitionQuality)
      }
    }
    gtk_widget_set_visible(cancelButton, 0)
    gtk_widget_set_visible(runButton, 0)

    ocrProgressLabel = progressLabel
    ocrProgressBar = progressBar
    ocrCancelButton = cancelButton
    ocrSummaryLabel = summaryLabel
    ocrPendingLabel = pendingLabel
    ocrRunButton = runButton

    // Mirrors `HistorySettingsView`'s `.task { await ocrBackfillViewModel
    // .refreshPendingCount() }` — loads the initial "N images have no
    // recognized text" count once, when this tab is first built.
    let viewModel = ocrBackfillViewModel
    Task { await viewModel.refreshPendingCount() }
  }

  /// One poll tick — reconciles the OCR backfill row's five widgets against
  /// `ocrBackfillViewModel`'s current state. Three mutually-exclusive
  /// states, in the exact same priority order as `HistorySettingsView
  /// .ocrBackfillRow`: a run in progress (progress label + bar + Cancel);
  /// nothing in progress but a previous run just finished (a one-line
  /// result); and the current pending count (Run button, or, if there's
  /// truly nothing to do, a plain statement instead of a button that would
  /// only ever no-op).
  @MainActor
  func pollOCRBackfillTick() -> Bool {
    guard let ocrProgressLabel, let ocrProgressBar, let ocrCancelButton,
      let ocrSummaryLabel, let ocrPendingLabel, let ocrRunButton
    else { return true }

    if ocrBackfillViewModel.isRunning {
      gtk_widget_set_visible(ocrCancelButton, 1)
      gtk_widget_set_visible(ocrSummaryLabel, 0)
      gtk_widget_set_visible(ocrPendingLabel, 0)
      gtk_widget_set_visible(ocrRunButton, 0)
      if let progress = ocrBackfillViewModel.progress, progress.total > 0 {
        setStatusLabel(
          ocrProgressLabel,
          text: "Recognizing images… \(progress.completed) of \(progress.total)")
        gtk_widget_set_visible(ocrProgressBar, 1)
        gtk_progress_bar_set_fraction(
          ocrProgressBar, Double(progress.completed) / Double(progress.total))
      } else {
        setStatusLabel(ocrProgressLabel, text: nil)
        gtk_widget_set_visible(ocrProgressBar, 0)
      }
      return true
    }

    setStatusLabel(ocrProgressLabel, text: nil)
    gtk_widget_set_visible(ocrProgressBar, 0)
    gtk_widget_set_visible(ocrCancelButton, 0)

    setStatusLabel(
      ocrSummaryLabel,
      text: ocrBackfillViewModel.lastSummary.map(Self.ocrFinishedSummaryText))

    switch ocrBackfillViewModel.pendingCount {
    case nil:
      setStatusLabel(ocrPendingLabel, text: nil)
      gtk_widget_set_visible(ocrRunButton, 0)
    case 0:
      setStatusLabel(ocrPendingLabel, text: "All images already have recognized text.")
      gtk_widget_set_visible(ocrRunButton, 0)
    case .some(let count):
      setStatusLabel(ocrPendingLabel, text: Self.ocrPendingCountText(count))
      gtk_widget_set_visible(ocrRunButton, 1)
    }
    return true
  }

  private static func ocrPendingCountText(_ count: Int) -> String {
    count == 1 ? "1 image has no recognized text." : "\(count) images have no recognized text."
  }

  private static func ocrFinishedSummaryText(_ summary: OCRBackfillSummary) -> String {
    let verb = summary.wasCancelled ? "Cancelled" : "Done"
    return "\(verb) — recognized text in \(summary.progress.recognized) of "
      + "\(summary.progress.total) image(s)."
  }

  /// How often `pollOCRBackfillTick()` runs — short enough that "Recognizing
  /// images… N of M" feels live while a run is in progress, cheap enough
  /// (a handful of property reads + conditional `gtk_widget_set_visible`/
  /// `gtk_label_set_text` calls) to cost nothing noticeable for the rest of
  /// the app's lifetime, matching `UpdateChecker`'s own "runs forever,
  /// negligible cost" steady state.
  static let ocrBackfillPollIntervalMilliseconds: UInt32 = 200

  /// Starts polling `ocrBackfillViewModel` — called once, from `init`
  /// (`SettingsWindow.swift`), after `buildHistoryTab()` has built every
  /// widget `pollOCRBackfillTick()` touches. Never stopped: this window is
  /// a permanent, app-lifetime singleton (see `ocrPollSourceID`'s doc
  /// comment on `SettingsWindow`).
  func startOCRBackfillPolling() {
    guard ocrPollSourceID == nil else { return }
    ocrPollSourceID = g_timeout_add_full(
      G_PRIORITY_DEFAULT,
      SettingsWindow.ocrBackfillPollIntervalMilliseconds,
      ocrBackfillPollTrampoline,
      retainedTrampolineContext(self),
      releaseTrampolineContextSingleArg)
  }
}

/// `GSourceFunc` — `gboolean (*)(gpointer user_data)`. Mirrors
/// `PickerWindow`'s former `pollTrampoline` shape exactly (see
/// `SettingsWindow.swift`'s top doc comment).
private let ocrBackfillPollTrampoline: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
  data in
  guard let window = unretainedContext(data, as: SettingsWindow.self) else { return 0 }
  return MainActor.assumeIsolated { window.pollOCRBackfillTick() } ? 1 : 0
}
