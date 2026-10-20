// PickerAnnouncer.swift
//
// T-AUD-VO: posts a VoiceOver announcement. The picker keeps keyboard focus
// in the search field while arrow keys move a *highlight*, so VoiceOver gets
// no focus-change event for the newly highlighted row; this speaks it
// instead. Chosen over an `accessibilityFocused` binding on the rows because
// moving AX focus off the search field would break type-to-search. A no-op
// unless VoiceOver is running.

import AppKit

@MainActor
enum PickerAnnouncer {
  static func announce(_ message: String) {
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
}
