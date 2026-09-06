// SnippetFormValidation.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): pure validation rule
// for `SnippetEditorWindow`'s Save button — mirrors macOS `SnippetFormView
// .isSaveDisabled` exactly ("Both fields are required — a snippet needs a
// name to find it by and content to be worth pasting"), inverted to a
// positive `isSaveEnabled` name for the GTK call site
// (`gtk_widget_set_sensitive`, which takes "is enabled," not "is disabled").
//
// Known, deliberate duplication (flagged, not accidental): the shared,
// cross-platform home for this rule would be `ClipnestViewModels`, but that
// module is explicitly out of this task's owned-files scope (read-only —
// two other agents are working there this session). Given that boundary,
// mirroring this ~2-line trim-and-check rule locally is the pragmatic
// choice over reaching into a module this task must not touch; a future
// task with `ClipnestViewModels` in scope could hoist both copies into one
// shared definition alongside `SnippetFormMode`.
import Foundation

public enum SnippetFormValidation {
  /// Both `tag` and `body` must be non-empty after trimming whitespace/
  /// newlines — identical rule to `SnippetFormView.isSaveDisabled`.
  public static func isSaveEnabled(tag: String, body: String) -> Bool {
    !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
