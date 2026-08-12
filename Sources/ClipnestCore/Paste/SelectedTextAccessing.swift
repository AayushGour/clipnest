import Foundation

/// Reads / replaces the frontmost app's current text selection via the
/// platform's accessibility layer, WITHOUT touching the pasteboard. The
/// concrete implementation (AX-backed) lives in the app target; this
/// protocol lives here so `SnippetExpander` is unit-testable with a mock.
public protocol SelectedTextAccessing {
  /// The currently-selected text in the focused UI element, or `nil` if
  /// there's no selection, no focused element, or it can't be read.
  func readSelectedText() -> String?

  /// Replaces the current selection with `text` in place. Returns `true`
  /// on success, `false` if the write was refused / unsupported.
  @discardableResult
  func replaceSelectedText(with text: String) -> Bool
}
