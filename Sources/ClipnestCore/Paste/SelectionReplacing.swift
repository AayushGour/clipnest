import Foundation

/// The result of a clipboard-based selection replace (see `SelectionReplacing`).
public enum SelectionReplaceResult: Sendable, Equatable {
  /// The selection was read, matched a snippet, and was replaced.
  case replaced
  /// Nothing readable was selected (synthesized Copy produced no text).
  case noSelection
  /// A selection was read but `bodyForSelection` returned no body for it.
  case noMatch
}

/// Universal, works-in-any-app fallback for replacing the current selection —
/// used by `SnippetExpander` when the Accessibility path can't read/replace the
/// selection (Electron/Chrome/Java apps don't expose selected text to AX).
///
/// The single method owns the ENTIRE clipboard transaction so the clipboard is
/// borrowed and restored atomically from the caller's point of view:
/// 1. suppress Clipnest's own capture,
/// 2. snapshot the current clipboard,
/// 3. synthesize Copy and read what the frontmost app put on the clipboard
///    (that's the current selection — the "keyword"),
/// 4. call `bodyForSelection` with it; if it returns a body, put the body on
///    the clipboard and synthesize Paste (replacing the selection),
/// 5. restore the original clipboard and re-enable capture.
///
/// Because it drives copy/paste keystrokes (which every app supports) rather
/// than AX text attributes, it works in EVERY application. The clipboard ends
/// up byte-for-byte as it started; the only cost is a brief window where it
/// transiently holds the selection/body, which step 5's restore + the capture
/// suppression hide.
///
/// `@MainActor`: it posts key events and touches `NSPasteboard` — main-thread
/// work — and is called from the `@MainActor` `SnippetExpander`. The concrete
/// implementation (`ClipboardSelectionReplacer`) lives in the app target; a
/// mock backs `SnippetExpander`'s tests.
@MainActor
public protocol SelectionReplacing {
  /// Runs the transaction described in the protocol doc. `bodyForSelection`
  /// receives the read selection and returns the replacement body, or `nil`
  /// if the selection matches nothing. Never throws — failures degrade to
  /// `.noSelection`/`.noMatch`.
  func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
}
