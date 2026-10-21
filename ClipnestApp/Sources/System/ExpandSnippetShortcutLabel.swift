// ExpandSnippetShortcutLabel.swift
//
// T-SNIPFB1: the user-visible name of the (rebindable) expand-snippet hotkey,
// for the snippet form's helper text and the failure HUD. Falls back to prose
// when the user has unbound it.

import ClipnestViewModels
import KeyboardShortcuts

enum ExpandSnippetShortcutLabel {
  @MainActor
  static var current: String {
    KeyboardShortcuts.getShortcut(for: .expandSnippet)?.description
      ?? SnippetExpansionCopy.unboundShortcutFallback
  }
}
