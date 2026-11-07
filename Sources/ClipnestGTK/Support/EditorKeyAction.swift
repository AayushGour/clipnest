// EditorKeyAction.swift
//
// T-EDIT14 / T-EDIT15: the editor popups' window-level keyboard chords as plain
// data, the editors' counterpart of `KeyEventMapping` (which does the same for
// the picker). `ItemEditorWindow`'s and `SnippetEditorWindow`'s capture-phase
// key controllers only switch over the result (the snippet editor passes
// `isRichText: false`, so Ctrl+B/I/U fall through to GTK), so the bindings
// live in one testable place with no GTK import. Keyvals and masks are GDK's
// public, ABI-stable constants (see `KeyEventMapping`'s top doc comment for why
// they're hardcoded).
//
// Bindings (Linux-conventional Ctrl, mirroring macOS's ⌘):
//   Esc          cancel (Go Back while the lossy row is up)
//   Ctrl+Return  save from anywhere
//   Ctrl+Tab     insert a literal tab character (the editor does not accept
//                a plain Tab: it moves focus). GtkTextView has no built-in
//                literal-tab path once `accepts-tab` is off -- its only
//                Ctrl+Tab binding moves focus -- so this is handled here.
//   Ctrl+B/I/U   toggle bold / italic / underline (GtkTextView has no such
//                bindings of its own)
public enum EditorKeyAction: Equatable, Sendable {
  case save
  case cancel
  case insertTab
  case toggleBold
  case toggleItalic
  case toggleUnderline

  private enum Keyval {
    static let escape: UInt32 = 0xff1b
    static let `return`: UInt32 = 0xff0d
    static let kpEnter: UInt32 = 0xff8d
    static let tab: UInt32 = 0xff09
    static let bLower: UInt32 = 0x062
    static let bUpper: UInt32 = 0x042
    static let iLower: UInt32 = 0x069
    static let iUpper: UInt32 = 0x049
    static let uLower: UInt32 = 0x075
    static let uUpper: UInt32 = 0x055
  }

  /// The action for a raw GTK key press, or nil when the editor leaves the
  /// key to GTK.
  /// - Parameters:
  ///   - focusInEditor: the text view holds focus. Ctrl+Tab and Ctrl+B/I/U
  ///     only apply there (elsewhere Ctrl+Tab keeps its focus-move meaning).
  ///   - isRichText: false for recognized-text mode (no formatting).
  public static func action(
    keyval: UInt32, state: UInt32, focusInEditor: Bool, isRichText: Bool
  ) -> EditorKeyAction? {
    let state = state & ~KeyEventMapping.lockMask  // Caps Lock is not a chord modifier
    let ctrl = state & KeyEventMapping.controlMask != 0
    let alt = state & KeyEventMapping.altMask != 0
    let shift = state & KeyEventMapping.shiftMask != 0
    let superKey = state & KeyEventMapping.superMask != 0
    switch keyval {
    case Keyval.escape:
      // Any modifier (Shift included) leaves Esc to GTK, consistently.
      return ctrl || alt || shift || superKey ? nil : .cancel
    case Keyval.return, Keyval.kpEnter:
      return ctrl && !alt && !superKey ? .save : nil
    case Keyval.tab:
      return ctrl && !alt && !shift && !superKey && focusInEditor ? .insertTab : nil
    case Keyval.bLower, Keyval.bUpper:
      return formatting(.toggleBold, ctrl, alt, shift, superKey, focusInEditor, isRichText)
    case Keyval.iLower, Keyval.iUpper:
      return formatting(.toggleItalic, ctrl, alt, shift, superKey, focusInEditor, isRichText)
    case Keyval.uLower, Keyval.uUpper:
      return formatting(.toggleUnderline, ctrl, alt, shift, superKey, focusInEditor, isRichText)
    default:
      return nil
    }
  }

  private static func formatting(
    _ action: EditorKeyAction, _ ctrl: Bool, _ alt: Bool, _ shift: Bool, _ superKey: Bool,
    _ focusInEditor: Bool, _ isRichText: Bool
  ) -> EditorKeyAction? {
    // No Shift: Ctrl+Shift+U is the IBus Unicode-input chord.
    ctrl && !alt && !shift && !superKey && focusInEditor && isRichText ? action : nil
  }
}
