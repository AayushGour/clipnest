// ItemEditorWindow.swift
//
// The edit-copied-item popup. A non-activating `EditorPanel` (see that file
// for why the editors must never activate Clipnest). Reused across `show`
// calls.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI

@MainActor
final class ItemEditorWindow: EditorPanel {
  /// Shows the editor and makes it key without activating Clipnest.
  ///
  /// - Parameters:
  ///   - mode: Content or recognized-text editing (toolbar only for content).
  ///   - loaded: The already-parsed editor content (`ItemEditPresenter` builds
  ///     it off the main thread via `MacEditableRichText.load`).
  ///   - richContentMissing: The item's stored formatting was missing or
  ///     unreadable (content mode shows the lossy warning).
  ///   - pickerPanel: Picker to lay out beside; `nil`/hidden centers.
  ///   - save: Persists the edit; never called by Cancel or window close.
  ///   - onSaved: Called when the picker list must refresh (saved, or a
  ///     failure that may have been partially applied).
  ///   - onClose: Called exactly once when the window closes for any reason.
  func show(
    mode: ItemEditMode,
    loaded: MacEditableRichText.Loaded,
    richContentMissing: Bool,
    pickerPanel: PickerPanel?,
    save: @escaping @MainActor (EditorOutput) async -> ItemEditOutcome,
    onSaved: @escaping @MainActor () -> Void,
    onClose: @escaping () -> Void
  ) {
    let isContent: Bool
    if case .content = mode { isContent = true } else { isContent = false }
    title = mode.title
    present(
      content: NSHostingView(
        rootView: ItemEditorView(
          mode: mode,
          isLossy: loaded.isLossy || (isContent && richContentMissing),
          initial: loaded.attributed,
          save: save,
          onSaved: onSaved,
          onCancel: { [weak self] in self?.close() }
        )
      ),
      pickerPanel: pickerPanel,
      onClose: onClose
    )
  }
}
