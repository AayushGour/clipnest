// PickerWindow+RowActions.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): the ONE place a resolved
// `ItemRowAction`/`SnippetRowAction` is dispatched to the matching
// `PickerViewModel` call — shared by both `PickerWindow+Rows.swift`'s
// always-visible trailing buttons AND `PickerWindow+ContextMenu.swift`'s
// right-click menu, so the pin/delete/etc. action is wired to
// `PickerViewModel` exactly once, not duplicated per surface. Every method
// this file calls already exists on the shared `PickerViewModel`
// (`ClipnestViewModels`, read-only this task) — nothing here reimplements
// pin/delete/snippet-CRUD logic.
import ClipnestCore
import ClipnestViewModels

extension PickerWindow {
  /// Dispatches one History/Pinned row action. `item` is the exact row the
  /// action was invoked against — captured by the caller (a button's
  /// "clicked" handler in `PickerWindow+Rows.swift`, or the context menu's
  /// per-entry handler in `PickerWindow+ContextMenu.swift`) at the moment
  /// the row was built/right-clicked, not re-resolved from `renderedRows`
  /// here — `ClipItem` is a `Sendable` value type, so capturing it by value
  /// is safe and always acts on the exact item the user saw, even if
  /// `renderedRows` has since changed.
  func performItemRowAction(_ action: ItemRowAction, for item: ClipItem) {
    MainActor.assumeIsolated {
      switch action {
      case .togglePin:
        viewModel.togglePin(item)
      case .saveAsSnippet:
        viewModel.presentSaveAsSnippetForm(from: item)
      case .copyRecognizedText:
        viewModel.copyRecognizedText(from: item)
      case .delete:
        viewModel.delete(item)
      }
    }
  }

  /// Dispatches one Snippets-tab row action — mirrors
  /// `performItemRowAction(_:for:)` above.
  func performSnippetRowAction(_ action: SnippetRowAction, for snippet: Snippet) {
    MainActor.assumeIsolated {
      switch action {
      case .edit:
        viewModel.presentEditSnippetForm(snippet)
      case .delete:
        viewModel.deleteSnippet(snippet)
      }
    }
  }
}
