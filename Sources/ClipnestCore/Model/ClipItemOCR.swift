// ClipItemOCR.swift
//
// Pure predicates deciding what a ClipItem's `kind` (plus, for
// `hasRecognizedText`, `ocrText`) supports acting on. Extracted here as the
// single definition of each (coding-standards.md DRY) because more than one
// UI call site needs the exact same test — see each property's doc comment
// for its call sites. Kept in Core so both are unit-testable without
// launching the UI — same rationale as `ClipItemPreview.swift`'s
// `isPreviewWorthy`.

import Foundation

extension ClipItem {
  /// Whether this item is a `.image` with non-empty on-device-recognized
  /// text (see `ocrText`'s doc comment). Always `false` for every other
  /// kind — `ocrText` is always `nil` there. Drives the picker row's
  /// OCR badge/"Copy Recognized Text" context-menu item (`ItemRow`) and the
  /// footer's contextual ⌥⏎ hint (`PickerView` via
  /// `PickerViewModel`/`ShortcutHints`, T-SET2).
  public var hasRecognizedText: Bool {
    kind == .image && !(ocrText ?? "").isEmpty
  }

  /// Whether "Save as Snippet" makes sense for this item — kinds whose
  /// `previewText` is the item's *full* content (`.text`/`.link`), so
  /// there's nothing lost by seeding a new snippet's Body from it.
  /// `.richText`/`.image`/`.file` would need a real content-conversion step
  /// this feature doesn't do, so it's kept off those kinds rather than
  /// silently no-oping or seeding a snippet with the wrong content (T-SET4).
  /// Single definition (coding-standards.md DRY) shared by the row's
  /// trailing button + context-menu item (`ItemRow`), the actual gating
  /// logic (`PickerViewModel.presentSaveAsSnippetForm(from:)`/
  /// `saveHighlightedAsSnippet()`), and the footer's ⌘S hint
  /// (`ShortcutHints`) — before T-SET4 these were three separately-written
  /// copies of the same `kind == .text || kind == .link` check, two of which
  /// (the ⌘S key handler and the footer hint) had drifted from the row's,
  /// which is what let ⌘S on a highlighted `.image` row silently open a
  /// save-as-snippet form the row's own UI never offered.
  public var supportsSaveAsSnippet: Bool {
    kind == .text || kind == .link
  }
}
