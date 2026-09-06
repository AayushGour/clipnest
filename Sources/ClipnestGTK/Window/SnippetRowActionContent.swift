// SnippetRowActionContent.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): the Snippets-tab
// counterpart of `ItemRowActionContent.swift` (see that file's doc comment
// for the overall rationale/ownership note) — mirrors macOS `SnippetRow
// .swift` exactly: two always-visible trailing actions (Edit, Delete) and a
// right-click context menu offering the identical two, in the identical
// order. Unlike `ItemRowActions`, there is no gating here — every snippet
// supports both actions unconditionally, so `buttons()`/`contextMenu()`
// return the same list; both are still exposed (rather than one shared
// property) so `PickerWindow+Rows.swift`/`PickerWindow+ContextMenu.swift`
// call symmetrically-named accessors, matching `ItemRowActions`'s shape.
import ClipnestCore

/// One row action a Snippets-tab row can offer. `PickerWindow
/// +RowActions.swift` is the single place that dispatches each case to the
/// matching `PickerViewModel` call.
public enum SnippetRowAction: Equatable, Sendable {
  case edit
  case delete
}

/// One fully-resolved entry — see `ItemRowActionEntry`'s doc comment; same
/// shape, `Snippet`'s action set.
public struct SnippetRowActionEntry: Equatable, Sendable {
  public let action: SnippetRowAction
  public let label: String
  public let isDestructive: Bool
}

public enum SnippetRowActions {
  private static func entries() -> [SnippetRowActionEntry] {
    [
      SnippetRowActionEntry(action: .edit, label: "Edit", isDestructive: false),
      SnippetRowActionEntry(action: .delete, label: "Delete", isDestructive: true),
    ]
  }

  /// The row's two always-visible trailing icon buttons — matches
  /// `SnippetRow.rowActions`.
  public static func buttons() -> [SnippetRowActionEntry] { entries() }

  /// The row's right-click context-menu entries — matches `SnippetRow.body`'s
  /// `.contextMenu` (identical two actions, identical order).
  public static func contextMenu() -> [SnippetRowActionEntry] { entries() }
}
