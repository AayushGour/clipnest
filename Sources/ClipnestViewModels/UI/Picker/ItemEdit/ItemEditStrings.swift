import ClipnestCore

/// All user-facing copy for editing a copied item. One definition shared by
/// the macOS and Linux editors so the wording can never drift apart.
public enum ItemEditStrings {
  public static let lossyWarning = "Some formatting in this item can't be kept."
  public static let itemGone = "This item no longer exists."
  public static let saveFailed = "Couldn't save your changes."
  public static let editTitle = "Edit Item"
  public static let editRecognizedTextTitle = "Edit Recognized Text"
  public static let save = "Save"
  public static let cancel = "Cancel"
  public static let saveAnyway = "Save Anyway"
  public static let goBack = "Go Back"
  public static let editActionLabel = "Edit"
  public static let editRecognizedTextActionLabel = "Edit Recognized Text"
  public static let boldLabel = "Bold"
  public static let italicLabel = "Italic"
  public static let underlineLabel = "Underline"
  /// Spoken by VoiceOver / Orca for the two lossy-warning buttons. Distinct
  /// from the visible titles and from each other, so an assistive tool (or a
  /// UI test reading the tree) can never mistake one for the other.
  public static let saveAnywayAccessibilityLabel =
    "Save Anyway, dropping the formatting that can't be kept"
  public static let goBackAccessibilityLabel = "Go Back to editing without saving"

  /// Modifier text for a shortcut hint: the Mac's ⌘ glyph vs Linux's `Ctrl+`.
  public static let macShortcutModifier = "⌘"
  public static let linuxShortcutModifier = "Ctrl+"

  /// Tooltip / help text for a formatting button: `"Bold (⌘B)"`,
  /// `"Bold (Ctrl+B)"`. `key` is the shortcut's letter.
  public static func shortcutHint(label: String, key: String, modifier: String) -> String {
    "\(label) (\(modifier)\(key))"
  }

  /// The label for the single "edit" row action (button, context-menu entry,
  /// accessibility action) — `nil` when `item` has no edit affordance at all.
  /// Gated only by the `ClipItem` predicates; recognized-text editing wins
  /// for images, exactly like `PickerViewModel.presentEditForm(for:)`.
  public static func actionLabel(for item: ClipItem) -> String? {
    if item.supportsRecognizedTextEdit { return editRecognizedTextActionLabel }
    if item.supportsContentEdit { return editActionLabel }
    return nil
  }
}
