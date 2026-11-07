/// A control in the edit popup that takes keyboard focus. The raw value is the
/// stable accessibility identifier macOS stamps on the matching view, so a
/// test can map the live key-view loop back to this list.
public enum ItemEditControl: String, Sendable, CaseIterable {
  case bold = "itemEditor.bold"
  case italic = "itemEditor.italic"
  case underline = "itemEditor.underline"
  case editor = "itemEditor.editor"
  case cancel = "itemEditor.cancel"
  case save = "itemEditor.save"
  /// The inline lossy-formatting warning's buttons (replace Cancel / Save).
  case goBack = "itemEditor.goBack"
  case saveAnyway = "itemEditor.saveAnyway"
}

/// The one definition of the popup's Tab order, shared by macOS and Linux.
/// Visual order, wrapping from the last control back to the first (Shift+Tab
/// reverses). Both platforms' layouts are built top-to-bottom, left-to-right
/// to match, and the macOS app test walks the live key-view loop against this.
public enum ItemEditFocusOrder {
  /// The focusable controls, in Tab order, for `mode`.
  /// - The formatting toolbar exists only for content editing, not for
  ///   recognized text (plain text, no formatting).
  /// - A disabled Save (empty editor, or a save in flight) is skipped.
  public static func controls(for mode: ItemEditMode, canSave: Bool) -> [ItemEditControl] {
    var order: [ItemEditControl] = []
    if case .content = mode { order += [.bold, .italic, .underline] }
    order += [.editor, .cancel]
    if canSave { order.append(.save) }
    return order
  }
}
