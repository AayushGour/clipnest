// SnippetExpansionCopy.swift
//
// T-SNIPFB1: user-facing wording for the snippet Tag helper text and for every
// way an expansion attempt can fail (previously a silent beep). One place, used
// by the macOS HUD and the Linux notification. The expand shortcut is passed in
// (it is platform specific and user-rebindable), never hardcoded here.
import ClipnestCore

public enum SnippetExpansionCopy {
  /// Shown under the Tag field in the snippet form.
  public static func tagHelperText(expandShortcut: String) -> String {
    "Type this tag in any app, select it, then press \(expandShortcut) to expand."
  }

  /// Title of the transient message / notification.
  public static let feedbackTitle = "Snippet not expanded"

  /// Used when the user has unbound the expand shortcut.
  public static let unboundShortcutFallback = "the expand-snippet shortcut"

  public static func message(for failure: SnippetExpansionFailure, expandShortcut: String)
    -> String
  {
    switch failure {
    case .noSelection:
      return "Nothing is selected. Select a snippet tag, then press \(expandShortcut)."
    case .noMatch:
      return "No snippet uses the selected text as its tag. Check the tag in the Snippets tab."
    case .permissionMissing:
      return
        "Clipnest needs Accessibility access to expand snippets. "
        + "Turn it on in Settings > Permissions."
    case .replaceFailed:
      return
        "Clipnest couldn't replace the selection in this app. "
        + "Try again, or paste the snippet from the picker."
    }
  }
}
