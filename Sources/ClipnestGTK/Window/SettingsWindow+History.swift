// SettingsWindow+History.swift
//
// P7-D (Linux port, GTK4 view layer): the History settings tab — the GTK
// counterpart of macOS's `HistorySettingsView`. Retention mode/limits and
// on-device text recognition, all backed directly by `SettingsStore`. See
// `SettingsWindow+General.swift`'s doc comment for the `@MainActor`/
// `MainActor.assumeIsolated` split this file follows too.
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
}
