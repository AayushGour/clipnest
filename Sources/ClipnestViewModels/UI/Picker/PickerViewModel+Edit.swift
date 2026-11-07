// PickerViewModel+Edit.swift
//
// T-EDIT4: the picker's side of "edit copied items" — gating which items
// can be edited and refreshing the list after the editor saves. The editor
// itself is presented by the platform through the required
// `presentItemEditor` init seam.

import ClipnestCore

extension PickerViewModel {
  /// Opens the platform editor for `item`. An image with recognized text
  /// edits that text; any other editable item (text/rich text/link) edits
  /// its content; everything else (files, images without recognized text)
  /// does nothing at all. The rule lives only in the `ClipItem` predicates.
  public func presentEditForm(for item: ClipItem) {
    if item.supportsRecognizedTextEdit {
      presentItemEditor(.recognizedText(item))
    } else if item.supportsContentEdit {
      presentItemEditor(.content(item))
    }
  }

  /// T-EDIT13: the in-picker Edit shortcut (⌘E / Ctrl+E). On the Snippets tab
  /// opens the highlighted snippet's edit form; on History/Pinned edits the
  /// highlighted item via `presentEditForm(for:)` (so files and OCR-less
  /// images stay a no-op). Nothing highlighted is a no-op.
  public func editHighlighted() {
    if activeTab == .snippets {
      if let snippet = highlightedSnippet { presentEditSnippetForm(snippet) }
    } else if let item = highlightedItem {
      presentEditForm(for: item)
    }
  }

  /// Re-queries the rows, keeping selection where possible. Called by the
  /// composition root after an editor saves: the picker stays open while the
  /// editor is up, and `handleExternalStoreChange` deliberately ignores
  /// `.updated`/`.deleted`, so the editor (the mutator here) refreshes
  /// explicitly. Unconditional — no `isVisible` gate.
  public func reloadAfterEdit() {
    scheduleRowsQuery(.softReconcile, text: currentSearchText, debounced: false)
  }
}
