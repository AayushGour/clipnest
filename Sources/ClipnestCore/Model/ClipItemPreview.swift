// ClipItemPreview.swift
//
// Pure predicate deciding whether a ClipItem gets a hover popover (see
// ItemPreview / ItemPreviewController in ClipnestApp). Kept in Core so it's
// unit-testable without launching the UI.

import Foundation

extension ClipItem {
  /// Whether this item should get a hover popover. All kinds do: text-bearing
  /// kinds and images show their content; a `.file` shows its name, size, and
  /// path — all from metadata captured at copy time, with NO file-system
  /// access (so it can't hit the TCC gate that froze the picker; that hang
  /// was the row's `icon(forFile:)` lookup, now a generic type icon).
  public var isPreviewWorthy: Bool {
    switch kind {
    case .file, .image, .text, .richText, .link:
      return true
    }
  }
}
