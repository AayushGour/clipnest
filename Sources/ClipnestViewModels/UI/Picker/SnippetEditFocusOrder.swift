// SnippetEditFocusOrder.swift
//
// T-EDIT15: the snippet editor popup's Tab order and copy, the counterpart of
// `ItemEditFocusOrder` / `ItemEditStrings` for the item editor. Shared by
// macOS and Linux so the two can't drift apart.

/// A control in the snippet editor that takes keyboard focus. The raw value is
/// the stable accessibility identifier macOS stamps on the matching view, so
/// a test can map the live key-view loop back to this list.
public enum SnippetEditControl: String, Sendable, CaseIterable {
  case tag = "snippetEditor.tag"
  case body = "snippetEditor.body"
  case cancel = "snippetEditor.cancel"
  case save = "snippetEditor.save"
}

/// The snippet editor's Tab order: visual order, wrapping from the last
/// control back to the first (Shift+Tab reverses).
public enum SnippetEditFocusOrder {
  /// A disabled Save (empty Tag or Body) is skipped.
  public static func controls(canSave: Bool) -> [SnippetEditControl] {
    var order: [SnippetEditControl] = [.tag, .body, .cancel]
    if canSave { order.append(.save) }
    return order
  }
}

/// User-facing copy for the snippet editor (Cancel / Save reuse
/// `ItemEditStrings`).
public enum SnippetEditStrings {
  public static let newTitle = "New Snippet"
  public static let editTitle = "Edit Snippet"
  /// Placeholder text and accessibility label of the single-line field.
  public static let tagLabel = "Tag"
  /// Accessibility label of the multi-line field.
  public static let bodyLabel = "Body"

  public static func title(isNew: Bool) -> String { isNew ? newTitle : editTitle }
}
