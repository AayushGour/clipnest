// ExpandSnippetShortcutLabel.swift
//
// T-SNIPFB1: the user-visible name of the (rebindable) global expand-snippet
// hotkey, read live from GSettings, for the snippet form's helper text and the
// failed-expansion notification. Prose fallback when unbound.
import ClipnestViewModels

public enum ExpandSnippetShortcutLabel {
  public static var current: String {
    GlobalHotkeyAccelerator.current(.expandSnippet)
      .flatMap { GlobalHotkeyAcceleratorValidation.displayLabel(for: $0) }
      ?? SnippetExpansionCopy.unboundShortcutFallback
  }
}
