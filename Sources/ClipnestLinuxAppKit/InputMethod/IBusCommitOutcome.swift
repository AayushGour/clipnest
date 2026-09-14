import Foundation

/// The result of ONE `IBusCommitClient.replaceSelection(bodyForSelection:)`
/// transaction. Cross-platform-inert — this type lives in
/// `ClipnestLinuxAppKit` (Linux-only), not `ClipnestCore`; mapping it onto
/// `ClipnestCore.SelectionReplaceResult` (the cross-platform result type
/// `SelectionReplacing` returns) is the composing type's job
/// (`LinuxIBusSelectionReplacer`, T-IBUS-REPLACER), which is also the ONLY
/// place `.committedUnconfirmed` gets added to that enum. See D-IBUS-6
/// (`.claude/project-context.md`) for the full reasoning this type encodes.
///
/// ## The gate is `SetSurroundingText`, not `FocusIn` (correction, T-IBUS-REPLACER)
/// An earlier design (the one `IBusCommitClient`'s own top doc comment
/// still described until this task) gated the whole transaction on
/// `FocusIn` alone, reasoning that its arrival proved a live recipient. The
/// same VM measurement this file's doc comment used to cite as SUPPORT for
/// that gate actually disproves it once read correctly: `FocusIn` arrived
/// ~1ms after `SetGlobalEngine` **even with no GUI text field focused at
/// all** — a bare SSH session against an idle desktop. `FocusIn` proves
/// only "the daemon bound our engine to SOME input context," never "a
/// receptive text-editable widget is ready." Keeping `FocusIn` as the
/// gate would make the fall-through-to-clipboard path essentially never
/// trigger — the transaction would proceed to `DeleteSurroundingText`+
/// `CommitText` against contexts with nothing actually listening, reporting
/// `.committedUnconfirmed` (TERMINAL, no retry) while nothing received the
/// text: strictly worse than the status quo bug this feature exists to
/// fix, because snippet expansion would silently do nothing and never fall
/// back.
///
/// The real gate (D-IBUS-5): once `FocusIn` confirms our engine is bound to
/// SOME context, `IBusCommitClient` emits `RequireSurroundingText`. A REAL
/// text-editable widget answers with a genuine, synchronous
/// `SetSurroundingText(text, cursor_pos, anchor_pos)` round trip — GTK's
/// `ibusimcontext.c` sets `IBUS_CAP_SURROUNDING_TEXT` optimistically on
/// every context and only discovers a SPECIFIC widget can't answer
/// reactively on the first `retrieve-surrounding` failure (logging a
/// warning and revoking the bit for that context from then on) — so a
/// non-answering widget is a real, expected case, not an error path. Its
/// arrival is strictly stronger proof than `FocusIn`, AND it gives
/// `IBusCommitClient` the selected text itself (`cursor_pos`/`anchor_pos`
/// mark the selection range) with no synthesized keystroke — the same
/// "recover the keyword with no keystroke" property that makes this tier
/// immune to Wayland's per-device modifier merging in the first place.
public enum IBusCommitOutcome: Sendable, Equatable {
  /// Either `FocusIn` never arrived on our engine (the daemon never even
  /// bound us to a context), or it arrived but `SetSurroundingText` never
  /// answered `RequireSurroundingText` within budget (no receptive widget
  /// at all). Either way this transaction PROVABLY had no live recipient:
  /// nothing was deleted, nothing was committed. The caller should fall
  /// through to the next tier (the clipboard tier, D-IBUS-1's tier 3)
  /// exactly as it would for any other non-terminal failure — this is NOT
  /// terminal, unlike `.committedUnconfirmed` below.
  case noLiveRecipient

  /// `SetSurroundingText` arrived (a real, receptive widget answered), but
  /// its own `cursor_pos`/`anchor_pos` were equal — nothing is actually
  /// highlighted there. Distinct from `.noLiveRecipient` for diagnostics
  /// (a live widget answered; it just has nothing selected), but the SAME
  /// fall-through contract: not terminal, the caller retries via the next
  /// tier exactly as `SnippetExpander`'s own Accessibility-tier "no
  /// selection readable" case already falls through today.
  case noSelection

  /// `SetSurroundingText` arrived and its `cursor_pos`/`anchor_pos`
  /// bracketed a genuine, non-empty selection, but the caller's
  /// `bodyForSelection` closure found no snippet for it. **Terminal** —
  /// the recovered selection is real (read directly off the focused
  /// widget's own live state, not inferred), so a clipboard-tier re-read
  /// would yield the same non-match; mirrors `SnippetExpander`'s existing
  /// Accessibility-tier "read succeeded, no match -> beep, do not fall
  /// through" contract exactly.
  case noMatch

  /// `SetSurroundingText` arrived, a real selection was recovered, and
  /// `bodyForSelection` matched — so `DeleteSurroundingText` +
  /// `CommitText` WERE issued — but both are fire-and-forget D-Bus SIGNALS
  /// with no acknowledgement (D-IBUS-6), so this can never be upgraded to
  /// a confirmed "replaced" the way `ClipnestCore.SelectionReplaceResult
  /// .replaced` implies. Per the standing never-report-unconfirmed-as-
  /// confirmed rule (coding-standards.md), a believed-but-unconfirmed
  /// commit must not fold into "success."
  ///
  /// **Terminal — the caller MUST NOT retry via another tier on this
  /// outcome.** A real commit reached a live recipient; retrying (e.g.
  /// falling through to the clipboard tier's copy/paste) risks a genuine
  /// DOUBLE INSERT if the IBus commit actually landed, which is strictly
  /// worse than today's baseline bug this whole feature exists to fix.
  /// This asymmetry (`.noLiveRecipient`/`.noSelection` retry,
  /// `.committedUnconfirmed`/`.noMatch` do not) is the entire reason these
  /// are separate cases rather than one shared "didn't confirm" outcome.
  case committedUnconfirmed

  /// IBus itself could not even be asked — no address resolved, no live
  /// daemon (T-IBUS-PIDLIVE), the connection failed, registration failed,
  /// or the very first `GetGlobalEngine` query (needed to know what to
  /// restore to) never got a reply. No switch was ever attempted, so
  /// nothing needs restoring. Falls through exactly like
  /// `.noLiveRecipient` — the two are kept distinct so a caller/log can
  /// tell "IBus isn't usable at all this session" apart from "IBus is up,
  /// but nothing was listening for this one attempt," the same
  /// diagnostic distinction `SelectionReplaceResult`'s own cases already
  /// draw elsewhere in this codebase (e.g. `.noSelection` vs `.noMatch`).
  case unavailable
}
