// HistorySettingsView.swift
//
// The History settings tab: choose how much history to keep (maps directly to
// SettingsStore.retentionCap -> ClipStore.enforceRetention) and clear it all.
// Pinned items are always kept, regardless of the cap. Retention derivation is
// unit-tested in SettingsStoreTests; this view is pure binding + a confirm.

import ClipnestCore
import SwiftUI

struct HistorySettingsView: View {
  @Bindable var settings: SettingsStore
  let clipStore: any ClipStore

  @State private var showClearConfirm = false
  @State private var clearError: String?

  init(settings: SettingsStore, clipStore: any ClipStore) {
    self.settings = settings
    self.clipStore = clipStore
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
      Text("This permanently deletes every captured item, including pinned ones. This can't be undone.")
    }
  }
}
