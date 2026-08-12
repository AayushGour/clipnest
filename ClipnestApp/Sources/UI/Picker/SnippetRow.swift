// SnippetRow.swift
//
// Plan task T23: a single row in the picker's Snippets tab. Mirrors
// `ItemRow.swift`'s shape/conventions exactly: `.onTapGesture` (not a
// wrapping `Button`) for tap-to-select so the trailing action buttons
// stay genuine siblings instead of nested buttons. Snippets have no "pin"
// concept, so the two actions here are Edit and Delete instead of
// ItemRow's Pin/Unpin and Delete.
//
// T23 fix round: the row shows `snippet.title` (the picker's "Tag" field —
// see `SnippetFormView.swift`'s doc comment) as its primary label; the
// earlier separate keyword badge is gone along with the form field that
// used to set it (`Snippet.keyword` is unused throughout the picker now).
// `query` drives search-match highlighting on the Tag and body preview via
// `HighlightedText` (item 5).
//
// Routed follow-up (2026-08-10): the two trailing actions now use the
// shared `ExpandingIconButton` (`UI/Components/ExpandingIconButton.swift`)
// instead of the old `RowActionButton` (deleted — this file and
// `ItemRow.swift` were its only two callers, both migrated together) — see
// `ItemRow.swift`'s doc comment for the full rationale, which applies here
// unchanged (same component, same defaults, no `isActive` semantics for
// either action).

import ClipnestCore
import SwiftUI

/// Renders one `Snippet`: its title (the "Tag" field) with search matches
/// highlighted, a truncated one-line preview of `body` (also highlighted),
/// and two always-visible trailing actions (edit, delete) plus a matching
/// right-click context menu. Tapping the row's main content pastes `body`
/// (`onSelect`) — the same "select = paste + dismiss" behavior
/// History/Pinned rows have via `ItemRow`.
struct SnippetRow: View {
  let snippet: Snippet
  /// The active search query, for match highlighting (`HighlightedText`) —
  /// empty when there's no active search, in which case this renders
  /// exactly as plain text.
  let query: String
  let onSelect: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void
  /// Reports pointer hover to `PickerViewModel.hoverItem(_:)` — drives the
  /// snippet's Body preview popover, mirroring `ItemRow`'s hover behavior.
  let onHover: (Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "text.quote")
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        HighlightedText(text: snippet.title, query: query)
          .lineLimit(1)

        HighlightedText(text: snippet.body, query: query)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 0)

      rowActions
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .onHover { onHover($0) }
    .contextMenu {
      Button("Edit", systemImage: "pencil", action: onEdit)
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }

  private var rowActions: some View {
    HStack(spacing: 8) {
      ExpandingIconButton(systemName: "pencil", title: "Edit", action: onEdit)
      ExpandingIconButton(systemName: "trash", title: "Delete", action: onDelete)
    }
  }
}
