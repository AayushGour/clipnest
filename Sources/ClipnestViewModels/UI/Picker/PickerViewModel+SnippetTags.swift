// PickerViewModel+SnippetTags.swift
//
// T-SNIPFB1: duplicate-Tag protection for the snippet form. The rule itself is
// `SnippetTagValidation` (pure); this file only supplies the data (a cached
// snapshot of the store, so the per-keystroke form check stays synchronous) and
// the authoritative re-check done right before a write.
import ClipnestCore
import Foundation

extension PickerViewModel {
  /// Opens the snippet form after refreshing the duplicate-tag snapshot. The
  /// form is shown immediately; the snapshot lands well before anyone types.
  func openSnippetEditor(_ mode: SnippetFormMode) {
    presentSnippetEditor(mode)
    Task { [weak self] in await self?.refreshSnippetTagSnapshot() }
  }

  func refreshSnippetTagSnapshot() async {
    snippetsForTagValidation = (try? await snippetStore.fetchAll()) ?? snippetsForTagValidation
  }

  /// The inline form error for `tag`, or `nil` if it can be saved. `editing` is
  /// the id of the snippet being edited (so keeping its own tag is allowed).
  public func snippetTagError(forTag tag: String, editing editingID: UUID?) -> String? {
    SnippetTagValidation.conflict(
      forTag: tag, editing: editingID, in: snippetsForTagValidation
    ).map(SnippetTagValidation.message(forConflict:))
  }

  /// Authoritative check against the live store just before a write (guards
  /// against a stale snapshot). Also refreshes the snapshot.
  func isSnippetTagAvailable(_ tag: String?, editing editingID: UUID?) async -> Bool {
    await refreshSnippetTagSnapshot()
    guard let tag else { return true }
    if SnippetTagValidation.conflict(
      forTag: tag, editing: editingID, in: snippetsForTagValidation) != nil
    {
      Self.logger.error("Refused to save snippet: tag already in use")
      return false
    }
    return true
  }
}
