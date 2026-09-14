import Foundation

/// Pure orchestration for ONE IBus commit transaction — switch global
/// engine -> wait for `FocusIn` (proof the engine is bound to SOME
/// context) -> ask for surrounding text (`RequireSurroundingText`) -> wait
/// for the one real positive signal that a RECEPTIVE widget exists
/// (`SetSurroundingText`, D-IBUS-5 — see `IBusCommitOutcome`'s own doc
/// comment for why `FocusIn` alone was found insufficient) -> recover the
/// selected keyword from `cursor_pos`/`anchor_pos` with no synthesized
/// keystroke -> ask the caller for a replacement body -> delete+commit on
/// a match -> ALWAYS attempt to restore, regardless of outcome. Every I/O
/// step is an injected closure (no `DBusConnection`, no `KeyValueStore`
/// concrete type), so the full sequencing this task's hardest correctness
/// requirements depend on — crash-safety persist-before-switch/
/// clear-after-confirmed-restore (D-IBUS-3), the terminal
/// `.committedUnconfirmed`/`.noMatch` vs. fall-through
/// `.noLiveRecipient`/`.noSelection` fork (D-IBUS-6), and "restore is
/// attempted no matter how the transaction ends" — is exercised directly
/// by `IBusCommitTransactionTests`, not only by a live VM run.
/// `IBusCommitClient` (the one real, live-socket caller) supplies every
/// closure from real `DBusConnection`/`KeyValueStore` calls and is itself
/// manual-verify only, matching `ShellHelperClient`/`ClipnestControlService`'s
/// own precedent.
struct IBusCommitTransaction {
  let crashSafety: IBusCrashSafetyStateMachine

  /// Reads the CURRENTLY active global engine, to know what to restore to
  /// later. `nil` means IBus itself could not even be asked (no reply at
  /// all to `GetGlobalEngine`) — `run()` bails out to `.unavailable`
  /// WITHOUT ever switching anything, since switching without a known
  /// restore target is a worse crash-safety hazard than not switching at
  /// all.
  let queryCurrentEngineName: () -> String?

  /// Best-effort: switches the global engine to OUR engine. Its own
  /// success/failure is deliberately NOT gating this transaction's
  /// outcome — `waitForFocusIn` below is the first real signal, not this
  /// closure's return. The daemon may need to deliver `FocusIn` to us
  /// before it can even reply to this call (the theory behind D-IBUS-4's
  /// two-connection split), so this closure's own completion is not
  /// awaited before proceeding to the wait.
  let switchToOurEngine: () -> Void

  /// Blocks (internally bounded — see `IBusCommitClient.focusInTimeout`)
  /// for `FocusIn` to arrive on our engine object. `true` means the daemon
  /// bound our engine to SOME input context — NOT proof a receptive
  /// widget exists (see `IBusCommitOutcome`'s doc comment); `false` means
  /// the daemon never bound us to anything at all, the weakest possible
  /// failure.
  let waitForFocusIn: () -> Bool

  /// Emits `RequireSurroundingText` on our engine's object path — only
  /// ever called after `waitForFocusIn` returns `true` (asking before the
  /// engine is bound to a context has nothing to route to). Fire-and-forget,
  /// like every other outbound engine signal.
  let requireSurroundingText: () -> Void

  /// Blocks (internally bounded — see `IBusCommitClient
  /// .surroundingTextTimeout`) for `SetSurroundingText` to arrive on our
  /// engine object. `nil` means it did not arrive within budget — no
  /// receptive widget, exactly as `IBusCommitOutcome.noLiveRecipient`
  /// documents. A non-`nil` snapshot is the strongest signal this whole
  /// protocol offers: a real, text-editable widget answered a genuine
  /// round trip. `cursorPos`/`anchorPos` are Unicode CHARACTER (codepoint)
  /// offsets into `text` — see `IBusInboundRequest.setSurroundingText`'s
  /// doc comment for the upstream citation.
  let waitForSurroundingText: () -> (text: String, cursorPos: UInt32, anchorPos: UInt32)?

  /// Given the selection recovered from the surrounding-text snapshot
  /// (never a synthesized keystroke — that is the whole point of this
  /// tier), asks the caller for a replacement body. `nil` means no
  /// snippet matched — terminal (`.noMatch`), never retried by a further
  /// tier, mirroring `SnippetExpander`'s own Accessibility-tier "read
  /// succeeded, no match" contract.
  let bodyForSelection: (String) async -> String?

  /// Issues `DeleteSurroundingText` + `CommitText`, in that order, on the
  /// SAME synchronous call this closure runs on — no `await`/`Task` hop
  /// is introduced by `IBusCommitTransaction` itself, and none is
  /// introduced between `bodyForSelection` returning and this closure
  /// running either (nothing destructive has happened before this point,
  /// so the one `await` this transaction performs is safely BEFORE any
  /// delete/commit, never between them). A caller that wraps async work
  /// inside THIS closure would reintroduce exactly the intervening-
  /// `FocusOut`-on-a-yield data-loss shape this task's brief calls out;
  /// `IBusCommitClient`'s own implementation of this closure is plain,
  /// synchronous `DBusConnection.send` calls for exactly this reason.
  /// `offsetFromCursor`/`characterCount` are computed by
  /// `IBusCommitClient.deleteOffsetAndCount(cursorPos:anchorPos:)` from
  /// the SAME snapshot `waitForSurroundingText` returned — see that
  /// function's own doc comment for the offset arithmetic.
  let deleteAndCommit: (_ offsetFromCursor: Int32, _ characterCount: UInt32, _ text: String) -> Void

  /// Attempts to restore the global engine to `previousEngineName`,
  /// returning whether that restore is CONFIRMED (a real method-return,
  /// not just "sent") — see `IBusCrashSafetyStateMachine
  /// .restoreAfterCommit`'s doc comment for what an unconfirmed/failed
  /// restore leaves behind.
  let restoreEngine: (_ previousEngineName: String) -> Bool

  /// Runs the whole transaction end to end. See each stored closure's doc
  /// comment for what it does and doesn't guarantee. `async` (unlike the
  /// pre-T-IBUS-REPLACER version of this type) solely because
  /// `bodyForSelection` is — every other step remains a plain synchronous
  /// closure call, so no additional suspension point exists beyond that
  /// one, necessary, awaited step.
  func run() async -> IBusCommitOutcome {
    guard let previousEngineName = queryCurrentEngineName() else {
      return .unavailable
    }
    crashSafety.persistBeforeSwitch(previousEngineName: previousEngineName)
    switchToOurEngine()

    let outcome = await determineOutcome()

    // Restore is attempted REGARDLESS of the outcome above: even a
    // fall-through outcome still means WE switched the global engine away
    // from the user's real one, and leaving it there is exactly the
    // crash-safety hazard D-IBUS-3 exists to prevent, even though nothing
    // crashed this particular time.
    crashSafety.restoreAfterCommit(
      previousEngineName: previousEngineName, setGlobalEngine: restoreEngine)

    return outcome
  }

  /// Split out of `run()` purely so the restore step above has ONE call
  /// site regardless of which branch below produced the outcome — every
  /// early return in this method is a genuine terminal/fall-through
  /// OUTCOME, never a skip of the restore that follows it.
  private func determineOutcome() async -> IBusCommitOutcome {
    guard waitForFocusIn() else { return .noLiveRecipient }

    requireSurroundingText()
    guard let snapshot = waitForSurroundingText() else { return .noLiveRecipient }

    guard
      let selection = IBusCommitClient.selectedText(
        in: snapshot.text, cursorPos: snapshot.cursorPos, anchorPos: snapshot.anchorPos)
    else { return .noSelection }

    guard let body = await bodyForSelection(selection) else { return .noMatch }

    let (offsetFromCursor, characterCount) = IBusCommitClient.deleteOffsetAndCount(
      cursorPos: snapshot.cursorPos, anchorPos: snapshot.anchorPos)
    deleteAndCommit(offsetFromCursor, characterCount, body)
    return .committedUnconfirmed
  }
}
