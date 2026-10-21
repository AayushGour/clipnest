// SnippetTagValidation.swift
//
// T-SNIPFB1: the Tag doubles as the expansion keyword and `findByKeyword`
// returns ONE match, so two snippets sharing a tag behave unpredictably. The
// snippet form (macOS SwiftUI + GTK) blocks saving a duplicate; the rule and
// the wording live here once so the two views cannot drift.
import ClipnestCore
import Foundation

public enum SnippetTagValidation {
  /// The OTHER snippet that already uses `tag` as its expansion keyword, or
  /// `nil` if the tag is free. Matching is `Snippet.normalizedKeyword` (trim +
  /// case-fold) — the same rule `SnippetStore.findByKeyword` applies — so
  /// "Sig" and " sig " conflict. `editingID` excludes the snippet being edited
  /// so re-saving it with its own tag is fine. Blank tags never conflict
  /// (blank is rejected elsewhere as a missing required field).
  public static func conflict(
    forTag tag: String, editing editingID: UUID?, in snippets: [Snippet]
  ) -> Snippet? {
    guard let needle = Snippet.normalizedKeyword(tag) else { return nil }
    return snippets.first {
      $0.id != editingID && Snippet.normalizedKeyword($0.keyword) == needle
    }
  }

  /// Inline form message naming the conflicting snippet.
  public static func message(forConflict snippet: Snippet) -> String {
    "Already used by the snippet \u{201C}\(snippet.title)\u{201D}. Choose a different tag."
  }

  /// What to show under the Tag field: the duplicate error when there is one,
  /// otherwise the "what is the Tag" helper. One decision for both platforms.
  public static func fieldNote(error: String?, expandShortcut: String) -> (
    text: String, isError: Bool
  ) {
    if let error { return (error, true) }
    return (SnippetExpansionCopy.tagHelperText(expandShortcut: expandShortcut), false)
  }
}
