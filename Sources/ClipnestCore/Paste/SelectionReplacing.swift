import Foundation

/// The result of a clipboard-based selection replace (see `SelectionReplacing`).
public enum SelectionReplaceResult: Sendable, Equatable {
  /// The selection was read, matched a snippet, and was replaced.
  case replaced
  /// Nothing readable was selected (synthesized Copy produced no text).
  case noSelection
  /// A selection was read but `bodyForSelection` returned no body for it.
  case noMatch
  /// A selection was read and matched a snippet, and a paste WAS attempted
  /// (best effort — see `LinuxClipboardSelectionReplacer.replaceSelection`),
  /// but the replacement body's clipboard write could never be confirmed
  /// before that paste was posted. T-SHELLHELPER-TIMEOUT1: a privileged
  /// write that silently fails (or times out) and degrades to a
  /// known-broken fallback must not be indistinguishable from a real
  /// success — the target app may have pasted stale, pre-transaction
  /// content instead of the snippet body. Treat this as a failure exactly
  /// like `.noSelection`/`.noMatch` (e.g. `SnippetExpander.expand()`'s own
  /// `if result != .replaced { beep() }` already does, with no code change
  /// needed there), never as `.replaced`.
  case writeUnconfirmed
  /// The mirror of `.writeUnconfirmed` for the COPY step, added by the
  /// T-COPYFLAKE1 investigation's review (finding "Escalation"):
  /// `LinuxClipboardSelectionReplacer` computes a third-state signal
  /// (`stillSentinel`) that can tell "nothing was selected" apart from
  /// "something WAS copied but this class's own detection missed the
  /// transition" — collapsing both into `.noSelection` would be exactly
  /// the dishonest-success shape `.writeUnconfirmed` was added to stop one
  /// task earlier, just on the read side instead of the write side. Treat
  /// this as a failure exactly like the other non-`.replaced` cases —
  /// `SnippetExpander.expand()`'s existing `if result != .replaced {
  /// beep() }` already does, with no code change needed there.
  case copyUnconfirmed
  /// T-TERMPASTE1: the target app is a known terminal emulator, so this
  /// transaction was declined BEFORE any clipboard I/O — no synthesized
  /// ⌘C/Ctrl+C, no synthesized ⌘V/Ctrl+V, no snapshot/restore, nothing.
  ///
  /// Every other case in this enum describes an outcome of RUNNING the
  /// copy → match → paste transaction. This one exists because the
  /// transaction's only replace mechanism — paste, with no explicit delete
  /// step, relying on "paste replaces the OS-level selection" — is true for
  /// AppKit/WebKit/Electron controls but categorically FALSE for terminal
  /// emulators: a mouse-drag highlight there is a cosmetic, copy-only
  /// artifact with no tie to the shell's real cursor position (confirmed
  /// live, 2/2 trials, Terminal.app: the highlighted keyword stayed put and
  /// the snippet body was appended right after it — a corrupting APPEND,
  /// not a replace, every single time this app's own drag-select-then-
  /// hotkey UX is used in a terminal). Sending N backspaces first (N = the
  /// highlighted text's length) was considered and rejected: verified
  /// against real source for both espanso and AutoKey (via DeepWiki, not
  /// assumed from marketing docs), every prior-art text expander that
  /// erases-then-injects does so ONLY because it tracked every keystroke of
  /// the trigger AS IT WAS TYPED, so the backspace count is a known,
  /// trusted quantity tied to the real cursor. This app's "keyword" is
  /// whatever the user mouse-drag-highlighted — a quantity never observed
  /// being typed and whose position relative to the real cursor is
  /// unknowable in a terminal. Backspacing that many characters would
  /// delete that many WRONG characters at the actual cursor position:
  /// silent, wrong-location data destruction, strictly worse than the
  /// visible append it would replace. Declining outright — the only choice
  /// that leaves the terminal byte-identical to before the hotkey was
  /// pressed — is the fix. Treated as a failure exactly like every other
  /// non-`.replaced` case: `SnippetExpander.expand()`'s existing `if result
  /// != .replaced { beep() }` already does this, no code change needed
  /// there. Kept as its own case (not folded into `.noSelection`, which
  /// would be false here — something WAS selected) for the same reason
  /// `.writeUnconfirmed`/`.copyUnconfirmed` are their own cases: a future
  /// reader/caller/log needs to be able to tell "declined, nothing
  /// touched" apart from "attempted and failed."
  case declinedTerminalTarget
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
