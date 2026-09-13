import ClipnestCore
import ClipnestPlatformLinux
import Foundation

/// The Linux analogue of macOS's `ClipboardSelectionReplacer`
/// (`ClipnestApp/Sources/System/ClipboardSelectionReplacer.swift`):
/// `SnippetExpander`'s universal, works-in-any-app fallback for the
/// snippet-expansion hotkey, used whenever `ATSPITextAccessor` can't
/// read/replace the focused element's selection (terminal emulators,
/// GTK3/Qt apps without `toolkit-accessibility`, Electron without
/// `--force-renderer-accessibility` — see that type's own realistic
/// coverage estimate).
///
/// Drives synthesized Copy/Paste through the SAME `SyntheticKeystrokePosting`
/// backend `Paster` uses for the picker's own paste (`Sources
/// /ClipnestPlatformLinux/Input/SyntheticKeystrokePosting.swift`'s doc
/// comment names this exact future caller: "a Linux clipboard-selection
/// replacer, out of this module's scope, reuses the same backend
/// instance's `post(_:)`") — never a second uinput/XTEST call site.
///
/// T-TERMPASTE1: `TerminalAppRegistry.modifiers(forAppIdentifier:)` is
/// consulted in `replaceSelection`, but for a DIFFERENT reason than its
/// usual Ctrl+C/Ctrl+V-vs-Ctrl+Shift+C/Ctrl+Shift+V chord-selection role
/// (still exactly what `Paster`'s own paste-from-picker chord needs, since
/// a terminal reassigns plain Ctrl+C to SIGINT and plain Ctrl+V to nothing
/// useful): a positive match here means this class DECLINES the whole
/// transaction instead of running it with a different chord. Reason: this
/// class's only replace mechanism is Copy-then-Paste with no delete step,
/// which relies on "paste replaces the OS-level selection" — true
/// everywhere else, false in a terminal, where a mouse-drag highlight is a
/// cosmetic, copy-only artifact disconnected from the shell's real cursor.
/// No chord fixes that; see `SelectionReplaceResult.declinedTerminalTarget`
/// for the full writeup, including why sending backspaces first was
/// considered and rejected.
///
/// Snapshots and restores the clipboard around the whole transaction via
/// `GTKClipboardWriting` + the injected pasteboard reader, so the user's
/// clipboard ends up unchanged — same contract as the macOS type. The
/// restore write (B1 fix) goes through the identical privileged/ordinary
/// channel pair as every other text write this class makes and its own
/// landing is confirmed, not fire-and-forget — see `restoreClipboard`'s doc
/// comment for the residual case this still can't cover (no Shell extension
/// AND the ordinary write silently no-ops for this class's background call
/// site), which is now at least logged rather than silent. Capture
/// suppression (`beginSuppression`/`endSuppression`) is wired by the
/// composition root to `ClipboardMonitor.pause()`/`ignore(changeCount:)`
/// + `resume()`, mirroring `AppEnvironment`'s wiring exactly.
///
/// Manual-verify only for the actual synthesized keystrokes/clipboard
/// I/O (no display in CI); `TerminalAppRegistryTests` already covers the
/// underlying identifier-matching logic this class's decline check reuses.
@MainActor
public final class LinuxClipboardSelectionReplacer: SelectionReplacing {
  private let poster: any SyntheticKeystrokePosting
  private let pasteboard: LinuxPasteboard
  private let writer: any PasteboardWriting
  private let frontmostAppProvider: any FrontmostAppReferenceProviding

  /// Reused, rather than re-implemented, for the snapshot/restore in T-BUG1:
  /// `pullRawPayload(from:)` already encodes the exact same "most-specific
  /// representation wins" priority (file → image → rich text → text) this
  /// type's own doc comment promises, and is the same logic every other
  /// capture path in the app is held to — a second, hand-rolled priority
  /// order here would be exactly the kind of drift-prone duplication
  /// coding-standards.md's DRY rule exists to prevent. Only the raw-payload
  /// half is used (never `classify(_:)`) — this replacer restores bytes, it
  /// never needs a `ClipItem`/hash/preview.
  private let payloadReader = PasteboardReader()

  private static let copyWaitStep: Duration = .milliseconds(15)
  private static let copyMaxWait: Duration = .milliseconds(500)
  private static let pasteSettle: Duration = .milliseconds(120)

  /// T-COPYFLAKE1 fix: a value written to the clipboard immediately before
  /// the synthesized Ctrl+C, so the wait below can poll for "the content is
  /// no longer this" (content comparison) instead of "the ownership-change
  /// SERIAL advanced" (event count) — see `replaceSelection`'s own comment
  /// at the write site for the full root-cause writeup and prior-art
  /// citation (CopyQ's `Scriptable::copy()`, verified against its actual
  /// `src/scriptable/scriptable.cpp` source, does exactly this: reset the
  /// clipboard to a sentinel, synthesize the copy, then poll the sentinel
  /// slot's CONTENT rather than wait for an event). Deliberately a FIXED
  /// literal, not a fresh random value per transaction — CopyQ's own
  /// sentinel ("invalid") is likewise fixed; this isn't a security token,
  /// only a liveness marker, so a fixed, sufficiently distinctive string is
  /// simpler to test and just as effective. Plain ASCII (no embedded NUL or
  /// exotic Unicode): a NUL byte risks silent truncation somewhere in the
  /// GTK/ICCCM text-marshalling round trip this value must survive
  /// byte-for-byte for the comparison below to mean anything.
  ///
  /// `internal`, not `private` — same precedent as
  /// `SnippetExpander.terminalBellByte`'s doc comment: exists so
  /// `LinuxClipboardSelectionReplacerTests` (`@testable import`) can pin
  /// this exact value directly in its `writer.writes` assertions, rather
  /// than every test guessing at or duplicating the literal.
  static let copySentinelValue = "CLIPNEST_COPY_SENTINEL_7f3a1c9e"

  /// Metadata-only diagnostics for this whole tier (routed bug report,
  /// 2026-09: snippet expansion silently did nothing in Firefox, and this
  /// class logged NOTHING at all — no entry, no tier decision, no timeout,
  /// no outcome — so every earlier diagnosis attempt had to infer this
  /// path's behavior from OUTSIDE the process). Every call below logs only
  /// booleans, enum/case names, and elapsed milliseconds — coding-
  /// standards.md's privacy rule: clipboard/selection CONTENT is never
  /// logged, only metadata about it (same discipline `Paster`'s existing
  /// `.notice` call site and every other `ClipnestLogger` use in this
  /// codebase already follows).
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "LinuxClipboardSelectionReplacer")

  public var beginSuppression: () -> Void = {}
  public var endSuppression: () -> Void = {}

  /// T-SNIPPET-FF1 root-cause fix: an optional PRIVILEGED text-clipboard
  /// write, tried before the ordinary `writer.writeString` below — used for
  /// EVERY text write this class makes, via the shared `writeText(_:)`
  /// helper: the expansion-body write this comment originally documented,
  /// (T-COPYFLAKE1) the copy sentinel written just before the synthesized
  /// Ctrl+C, and (B1) the clipboard-restore write at the end of the
  /// transaction — all three for the identical reason — see
  /// `ShellHelperClient.setClipboardText`'s doc comment for the full
  /// mechanism and evidence. `writer.writeString` (`gdk_clipboard_set_text`)
  /// silently never takes effect for THIS call site specifically, because
  /// this whole method runs with no Clipnest window ever holding Wayland
  /// keyboard focus (triggered by a background global-hotkey handler, not
  /// a click inside a live Clipnest window) — unlike, say, the picker's
  /// own copy-on-select, which runs from inside a real click on a real,
  /// focused Clipnest window and therefore has a legitimate input serial.
  /// `nil` (the default) falls back to `writer.writeString` exactly as
  /// before: correct whenever the optional GNOME Shell extension isn't
  /// installed/active, matching every other `ShellHelperClient`
  /// capability's existing "degrade the feature, don't fail the call"
  /// contract in this codebase. Wired by the composition root
  /// (`LinuxAppLifecycle.wireShellHelper`) once a `ShellHelperClient`
  /// exists — required to exist as an explicit, non-defaulted ARGUMENT
  /// would be wrong here (unlike `reinstallToggleHotkeyFloor`'s "never
  /// silently forgotten" cross-platform-seam case): the Shell extension is
  /// a genuinely OPTIONAL, runtime-detected capability, not a seam every
  /// composition root must remember to wire — the exact same shape as
  /// `ShellHelperClient`'s own `.placement`/`.hotkeys` capabilities.
  public var privilegedTextWriter: ((String) -> Bool)?

  /// T-COPYFLAKE1 diagnostics: the compositor's OWN focused-window identity
  /// at the exact instant of the synthesized Ctrl+C, wired by the
  /// composition root to `ShellHelperClient.getFocusedApp()` when the
  /// optional GNOME Shell extension is active (same runtime-detected,
  /// degrade-don't-fail contract as `privilegedTextWriter` above, and
  /// deliberately NOT a required init parameter for the same reason).
  ///
  /// Why this exists at all: three separate measurements of this method's
  /// copy step disagreed (17.4%, 71.4%, 0% failure), and the leading
  /// explanation was that the TEST HARNESS's AT-SPI "the marker is
  /// selected and focused" check can pass while OS-level keyboard focus is
  /// somewhere else — in which case the synthesized Ctrl+C reaches the
  /// wrong window, nothing is copied, and `.noSelection` is CORRECT. That
  /// hypothesis is unfalsifiable from inside this process unless the
  /// process records who actually had focus. On Wayland only the
  /// compositor knows: `_NET_ACTIVE_WINDOW` reports X11 `None` for a
  /// native-Wayland focused window, and AT-SPI reports whatever last
  /// claimed the `FOCUSED` state. Metadata only (`ShellFocusedApp`
  /// carries app id / WM class / pid / window serial / client type — no
  /// window title, no selection bytes).
  public var focusProbe: (() -> ShellFocusedApp?)?

  public init(
    poster: any SyntheticKeystrokePosting,
    pasteboard: LinuxPasteboard,
    writer: any PasteboardWriting,
    frontmostAppProvider: any FrontmostAppReferenceProviding
  ) {
    self.poster = poster
    self.pasteboard = pasteboard
    self.writer = writer
    self.frontmostAppProvider = frontmostAppProvider
  }

  public func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    // T-TERMPASTE1: decided BEFORE anything else touches the clipboard. The
    // full writeup lives on `SelectionReplaceResult.declinedTerminalTarget`
    // and on macOS's `ClipboardSelectionReplacer` file header, which this
    // class mirrors. Short version: this transaction's only replace
    // mechanism is Copy-then-Paste with NO delete step, which relies on
    // "paste replaces the OS-level selection" — true everywhere else, false
    // for terminal emulators, where a mouse-drag highlight is a cosmetic,
    // copy-only artifact disconnected from the shell's real cursor. Reusing
    // `TerminalAppRegistry` here for a completely different reason than its
    // usual one: normally a positive match decides Ctrl+Shift+C/V vs. plain
    // Ctrl+C/V (chord selection) so copy/paste FUNCTIONS at all in a
    // terminal; here a positive match instead means "never attempt this
    // transaction," full stop — chord selection only fixes whether
    // copy/paste fires, never the missing-delete-step corruption once it
    // does.
    let frontmostRef = frontmostAppProvider.currentFrontmostAppRef()
    let isTerminalTarget =
      TerminalAppRegistry.modifiers(forAppIdentifier: frontmostRef?.bundleID) == [
        .control, .shift,
      ]
    Self.logger.notice(
      "terminal-target check: isTerminalTarget=\(isTerminalTarget) x11FrontmostBundleID=\(frontmostRef?.bundleID ?? "?") x11FrontmostPID=\(frontmostRef.map { String($0.processIdentifier) } ?? "?")"
    )
    guard !isTerminalTarget else {
      // Decline BEFORE any clipboard I/O — no suppression, no snapshot, no
      // synthesized keystroke, nothing for a failed restore to strand.
      Self.logger.notice("outcome=declinedTerminalTarget")
      return .declinedTerminalTarget
    }

    let transactionStart = ProcessInfo.processInfo.systemUptime
    Self.logger.notice(
      "clipboard-fallback tier: transaction started serial=\(pasteboard.changeCount) owner=\(Self.ownerDescription(pasteboard.selectionOwnerWindowID)) load1=\(Self.loadAverage1) \(Self.focusDescription(focusProbe))"
    )

    beginSuppression()
    let snapshot = payloadReader.pullRawPayload(from: pasteboard)
    let result = await runTransaction(snapshot: snapshot, bodyForSelection: bodyForSelection)

    // B1 fix: restoring the clipboard used to run inside this method's own
    // `defer`, which is why it could only ever be a fire-and-forget write —
    // Swift does not allow `await` inside a `defer` body, so there was no
    // way to confirm the restore actually landed before this method
    // returned. `runTransaction` below never throws (it has no `try`
    // anywhere in it), so calling the restore as a plain, explicit step
    // right after it returns is exactly equivalent to the old defer for
    // every real exit path, while finally letting `restoreClipboard`
    // `await` its own confirmation.
    await restoreClipboard(snapshot)
    endSuppression()
    Self.logger.notice(
      "clipboard-fallback tier: transaction ended, totalElapsedMs=\(Self.elapsedMs(since: transactionStart))"
    )
    return result
  }

  /// The copy/match/paste transaction proper — split out of
  /// `replaceSelection` solely so the clipboard-restore step above can be
  /// `await`ed after this returns (see that method's own comment for why).
  /// No behavior here differs from before this task's fixes except where a
  /// `// B1`/`// N1`/`// N2` comment below marks one.
  ///
  /// T-TERMPASTE1: only ever reached for a NON-terminal frontmost target —
  /// `replaceSelection` above declines and returns before calling this for
  /// any target `TerminalAppRegistry` matches. Copy/paste below always uses
  /// plain `.control`; the Ctrl+Shift chord `TerminalAppRegistry` can also
  /// return is for a DIFFERENT caller (the picker's own paste-from-history
  /// flow, which has no delete step to get wrong) and is never reachable
  /// from here anymore, so computing it in this method would just be dead
  /// code asserting a branch that can never be taken.
  private func runTransaction(
    snapshot: PasteboardReader.RawPayload?,
    bodyForSelection: (String) async -> String?
  ) async -> SelectionReplaceResult {
    // T-COPYFLAKE1 ROOT CAUSE: `waitForChange` below used to poll
    // `pasteboard.changeCount` (`X11ClipboardConnection.changeSerial`),
    // which only advances on an observed `XFixesSelectionNotify` EVENT.
    // Confirmed against mutter's own source
    // (`src/x11/meta-x11-selection.c`, `notify_selection_owner`): mutter's
    // X11 bridge calls `XSetSelectionOwner` -- the ONLY thing that can ever
    // produce that event on Clipnest's watched connection -- solely when
    // `new_owner != x11_display->selection.owners[selection_type]`, an
    // OBJECT-IDENTITY comparison against whichever `MetaSelectionSource`
    // last owned the selection. That is an EVENT count, not a WRITE count:
    // any path where a redundant/no-visible-change re-assertion of
    // ownership is coalesced away before this comparison never fires the
    // event, so `changeCount` never advances and this wait always burns
    // its full ceiling -- indistinguishable, from `waitForChange`'s POV,
    // from "the target app never copied anything at all". This asymmetry
    // has no macOS analogue (`NSPasteboard.changeCount` increments on
    // every WRITE, unconditionally).
    //
    // Fix, modeled on CopyQ's `Scriptable::copy()` (verified against its
    // real `src/scriptable/scriptable.cpp`, not assumed from
    // documentation): write a SENTINEL value into the exact same `.string`
    // slot this class already reads at "selection read" below, then poll
    // that slot's CONTENT for "no longer equals the sentinel" instead of
    // waiting for an ownership-change event. A real copy necessarily
    // overwrites the sentinel with the target's actual selection, so
    // content differing from the sentinel is a direct, positive signal
    // that a write happened -- true whether or not an XFixesSelectionNotify
    // fired for it. Alternatives considered and rejected:
    //   - A larger `copyMaxWait`: rejected by the task's OWN measurement --
    //     every failure pegs at the CURRENT ceiling with no middle ground,
    //     so the copy is not slow, it is (from this wait's POV) invisible;
    //     a bigger timeout only makes every genuine no-selection case
    //     slower without fixing anything.
    //   - Widening `X11ClipboardConnection`'s XFixes registration or
    //     comparing `XFixesSelectionNotify`'s `selection-timestamp` instead
    //     of relying on mutter's bridge: mutter's bridge is the piece that
    //     decides whether to re-call `XSetSelectionOwner` at all, and it
    //     lives entirely outside this process (`meta-x11-selection.c`) --
    //     not something Clipnest's X11 client can widen or bypass from the
    //     watching side.
    //   - `XConvertSelection`-and-compare on every poll tick (bypassing
    //     `changeCount` and the sentinel entirely, always re-fetching TARGETS
    //     fresh): correct in principle but a real round trip PER POLL TICK
    //     (~33 ticks over 500ms) against every app's selection owner, vs.
    //     one sentinel write plus reading a value already cached locally by
    //     `X11ClipboardConnection` for the rest of the poll -- strictly more
    //     load on every third-party selection owner for no accuracy gain
    //     the sentinel doesn't already provide.
    //
    // Bootstrapping hazard this fix must not introduce: writing the
    // sentinel does not make it appear in `pasteboard.string(forType:)`
    // SYNCHRONOUSLY -- `writer`/`privilegedTextWriter` (GDK/Shell-extension
    // writes) and `pasteboard` (`X11ClipboardConnection`, a separate raw
    // Xlib connection) are two independent channels, exactly like the
    // expansion-body write below; the sentinel becomes visible to
    // `pasteboard` only after the SAME asynchronous mutter-re-owns/XFixes
    // round trip. Polling for "content != sentinel" before that round trip
    // completes would see whatever STALE content was there before the
    // sentinel write and misreport it as a fresh copy on the very first
    // tick. So the sentinel's OWN landing is confirmed first, via the
    // existing event-based `waitForChange` -- this is confirming
    // Clipnest's OWN write, the same mechanism already measured reliable
    // for the expansion-body write (T-SHELLHELPER-TIMEOUT1, 19/19 in the
    // white-box run), not a third party's, so the event/write-count
    // asymmetry above does not apply the same way to it. If that
    // confirmation itself cannot be observed within the ceiling (e.g. no
    // Shell extension AND the ordinary GDK write silently no-ops per
    // T-SNIPPET-FF1's finding), this falls back to the ORIGINAL
    // event-based wait for the copy step too -- never worse than before
    // today, and copy detection on a no-extension machine keeps working
    // exactly as it always has, since it never depended on Clipnest's own
    // write succeeding in the first place.
    let beforeSentinel = pasteboard.changeCount
    let sentinelWriteStart = ProcessInfo.processInfo.systemUptime
    // B1/DRY fix: this used to be a hand-rolled `privilegedTextWriter?(...)
    // ?? false` + `if !... { writer.writeString(...) }` pair, duplicated
    // verbatim at the expansion-body write site below AND a third time at
    // the clipboard-restore site (`restoreClipboard`) — exactly the
    // drift-prone duplication coding-standards.md's DRY rule exists to
    // stop, and the actual mechanism of the B1 bug (the restore site's own
    // copy of this logic was allowed to skip the privileged half
    // entirely). Extracted once into `writeText(_:)`, used by all three.
    let sentinelViaShellHelper = writeText(Self.copySentinelValue)
    let sentinelWait = await waitForChange(after: beforeSentinel)
    let sentinelConfirmed = sentinelWait.satisfied
    // N1 fix: read back directly, rather than only inferring from the
    // EVENT count above — see the copy-step wait selection below for why
    // this direct read, not `sentinelConfirmed`, is what decides the
    // strategy there. Kept as its own named value (not re-derived at the
    // call site) so this exact log line and that later decision are
    // provably looking at the same read.
    let sentinelReadBack = Self.isSentinelOnClipboard(pasteboard)
    Self.logger.notice(
      "copy sentinel: viaShellHelper=\(sentinelViaShellHelper) confirmed=\(sentinelConfirmed) elapsedMs=\(Self.elapsedMs(since: sentinelWriteStart)) pollTicks=\(sentinelWait.ticks) serialBefore=\(beforeSentinel) serialAfter=\(pasteboard.changeCount) ownerAfter=\(Self.ownerDescription(pasteboard.selectionOwnerWindowID)) sentinelReadBack=\(sentinelReadBack)"
    )

    let beforeCopy = pasteboard.changeCount
    let ownerBeforeCopy = pasteboard.selectionOwnerWindowID
    // Probed BEFORE the keystroke, deliberately: this is the focus state
    // that decides which window receives the Ctrl+C, so probing after it
    // would record the consequence rather than the cause.
    let focusAtCopy = Self.focusDescription(focusProbe)
    let copyPostStart = ProcessInfo.processInfo.systemUptime
    let copyPosted = poster.post(KeyChord(modifiers: .control, character: "c"))
    Self.logger.notice(
      "copy keystroke: posted=\(copyPosted) elapsedMs=\(Self.elapsedMs(since: copyPostStart)) serialBefore=\(beforeCopy) ownerBefore=\(Self.ownerDescription(ownerBeforeCopy)) load1=\(Self.loadAverage1) \(focusAtCopy)"
    )
    guard copyPosted else {
      Self.logger.notice("outcome=noSelection reason=copyPostFailed")
      return .noSelection
    }

    let waitStart = ProcessInfo.processInfo.systemUptime
    // N1 fix: decide on `sentinelReadBack` — direct, positive CONTENT proof
    // the sentinel is actually on the clipboard right now — not
    // `sentinelConfirmed`, the EVENT-count confirmation above. Gating on the
    // event count was self-defeating: this whole mechanism exists BECAUSE
    // an event can fail to fire even though a real write landed (the exact
    // asymmetry documented above for third-party copies), so using that
    // same unreliable signal to decide whether to trust the more reliable
    // content-comparison check could throw away the fix's own benefit on
    // the very write it controls best (its own sentinel). `sentinelReadBack`
    // has no such asymmetry: it is a direct read, not an inference from a
    // coalescible event. `sentinelConfirmed` is still computed and logged
    // above for its own diagnostic value — the two disagreeing is itself a
    // fact worth being able to see, not something to silently paper over.
    let wait =
      sentinelReadBack
      ? await waitForSentinelToClear(Self.copySentinelValue)
      : await waitForChange(after: beforeCopy)
    let observedChange = wait.satisfied
    Self.logger.notice(
      "waitForChange: observedChange=\(observedChange) elapsedMs=\(Self.elapsedMs(since: waitStart)) ceilingMs=\(Int(Self.copyMaxWaitSeconds * 1000)) viaSentinel=\(sentinelReadBack) sentinelEventConfirmed=\(sentinelConfirmed) pollTicks=\(wait.ticks) serialAfter=\(pasteboard.changeCount) ownerAfter=\(Self.ownerDescription(pasteboard.selectionOwnerWindowID))"
    )
    guard observedChange else {
      // T-COPYFLAKE1 post-mortem probe — the single measurement that
      // separates the two candidate explanations for a failed copy, and
      // the reason this whole diagnostic block exists:
      //
      //   stillSentinel=true  -> the clipboard STILL holds Clipnest's own
      //                          sentinel, i.e. the synthesized Ctrl+C
      //                          produced no clipboard write at all. There
      //                          was genuinely nothing to copy (wrong
      //                          window focused, empty selection, chord
      //                          swallowed). `.noSelection` is CORRECT and
      //                          this is not a detection bug.
      //   stillSentinel=false -> the clipboard content no longer matches
      //                          what it was compared against — MEANINGFUL
      //                          only when `sentinelReadBack` (same line,
      //                          not two sections away — a review of this
      //                          exact code found three prior incidents
      //                          where the qualifier and the fact it
      //                          qualified were far enough apart in the
      //                          logs to be attributed independently) was
      //                          true, i.e. content-comparison is what ran
      //                          and it STILL timed out: a genuine
      //                          contradiction, a detection bug in this
      //                          class. When `sentinelReadBack` is false,
      //                          the event-based fallback ran instead, and
      //                          `stillSentinel` is UNINFORMATIVE there —
      //                          content was never provably the sentinel to
      //                          begin with (the sentinel write itself
      //                          never confirmed), so "no longer equals the
      //                          sentinel" is trivially true regardless of
      //                          whether anything was actually copied.
      //
      // Without this line the two are indistinguishable in the logs, which
      // is exactly how the same failure got attributed three different
      // ways across three measurement sessions. `targetsCount`/`textLen`
      // are counts, never content (coding-standards.md's never-log-content
      // rule); `XConvertSelection` reaching the owner at all is itself the
      // fact under test, so a zero count is meaningful, not noise.
      let probeStart = ProcessInfo.processInfo.systemUptime
      let stillSentinel = Self.isSentinelOnClipboard(pasteboard)
      let targets = pasteboard.availableTypes.count
      let textLength = pasteboard.string(forType: .string)?.count ?? -1
      Self.logger.notice(
        "copy failure probe: stillSentinel=\(stillSentinel) sentinelReadBack=\(sentinelReadBack) targetsCount=\(targets) textLenChars=\(textLength) owner=\(Self.ownerDescription(pasteboard.selectionOwnerWindowID)) serial=\(pasteboard.changeCount) probeElapsedMs=\(Self.elapsedMs(since: probeStart)) load1=\(Self.loadAverage1) \(Self.focusDescription(focusProbe))"
      )
      // Escalation fix (T-COPYFLAKE1 review): `stillSentinel=false` was
      // computed and logged, then discarded, always returning the same
      // `.noSelection` regardless — `SnippetExpander`'s caller had no way
      // to tell "nothing was selected" apart from "something WAS copied and
      // both waits missed it". Only meaningful when `sentinelReadBack` was
      // true (see the decision-table comment above); otherwise this falls
      // through to the historical `.noSelection` behavior, unchanged from
      // before this fix — a no-Shell-extension machine's copy detection
      // still works exactly as it always has.
      if sentinelReadBack && !stillSentinel {
        Self.logger.notice("outcome=copyUnconfirmed reason=contentChangedButBothWaitsMissedIt")
        return .copyUnconfirmed
      }
      Self.logger.notice("outcome=noSelection reason=noClipboardChangeObservedWithinCeiling")
      return .noSelection
    }

    let selectionReadStart = ProcessInfo.processInfo.systemUptime
    let selection = pasteboard.string(forType: .string) ?? ""
    let isSelectionEmpty = selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    Self.logger.notice(
      "selection read: empty=\(isSelectionEmpty) lengthChars=\(selection.count) elapsedMs=\(Self.elapsedMs(since: selectionReadStart))"
    )
    guard !isSelectionEmpty else {
      Self.logger.notice("outcome=noSelection reason=selectionEmptyAfterRead")
      return .noSelection
    }
    guard let body = await bodyForSelection(selection) else {
      Self.logger.notice("outcome=noMatch reason=bodyForSelectionReturnedNil")
      return .noMatch
    }
    Self.logger.notice("bodyForSelection: matched=true")

    // T-SNIPPET-FF1 ROOT CAUSE (confirmed live on the VM, 2026-09-13 — an
    // earlier "race with the paste" hypothesis, timed via this same
    // instrumentation, turned out to be WRONG and is corrected here):
    // `writer.writeString` (`gdk_clipboard_set_text`) never took effect at
    // ALL for this call site — not late, not racy, NEVER — confirmed three
    // independent ways: `waitForChange` below timed out on every single
    // run with no exception; a raw `XConvertSelection` probe run mid-
    // transaction (long before any restore could interfere) still showed
    // the pre-expansion text; and the target app's own subsequent paste
    // genuinely pasted back the unchanged pre-expansion text. Root cause,
    // confirmed against GTK's own Wayland backend source: GDK's Wayland
    // clipboard write (`gdk_wayland_device_set_selection`) requires a
    // FRESH input-event serial from Clipnest's own `GdkWaylandSeat` before
    // it will call `wl_data_device_set_selection` — a background process
    // reacting to a global hotkey (no Clipnest window ever gains keyboard
    // focus during this whole method) never has one, so the compositor
    // SILENTLY drops the request per Wayland's anti-clipboard-hijack
    // design: no error, no `false` return, nothing. This has no macOS
    // analogue (`NSPasteboard.setString` has no focus/serial gate) and no
    // effect on the AT-SPI tier (never touches the clipboard at all) —
    // which is exactly why this was Firefox/clipboard-fallback-only.
    //
    // Fix: `privilegedTextWriter` (when the optional GNOME Shell extension
    // is installed/active) routes through the compositor's OWN internal
    // `Meta.Selection.set_owner` API instead — no client-side Wayland
    // protocol round trip, hence no serial gate — see `ShellHelperClient
    // .setClipboardText`'s doc comment for the full mechanism. Falling
    // back to `writer.writeString` when it's `nil` or returns `false`
    // (extension not installed/active) is strictly no worse than today's
    // existing, already-broken-for-this-case behavior — never a
    // regression, only a possible non-fix on a machine without the
    // extension. `waitForChange` below is unchanged from before but now
    // MEANS something: `Meta.Selection.set_owner` fires the exact same
    // `MetaSelection::owner-changed` mutter uses to re-own the X11
    // CLIPBOARD selection (confirmed via `ClipboardWatcher.start()`
    // watching that identical signal, `extension/src/core/clipboard.js`),
    // so this wait now actually observes the privileged write succeeding
    // — unlike the GDK path, which never fired that signal in the repro
    // above. Still best-effort on a timeout (proceeds to paste anyway)
    // for the no-extension fallback case, where this wait is expected to
    // time out exactly as it always has.
    let beforeWrite = pasteboard.changeCount
    let writeStart = ProcessInfo.processInfo.systemUptime
    // B1/DRY fix: see the copy-sentinel write above — same shared helper.
    let wroteViaShellHelper = writeText(body)
    let writeWait = await waitForChange(after: beforeWrite)
    let writeObserved = writeWait.satisfied
    Self.logger.notice(
      "write propagation: viaShellHelper=\(wroteViaShellHelper) observed=\(writeObserved) elapsedMs=\(Self.elapsedMs(since: writeStart)) pollTicks=\(writeWait.ticks) serialBefore=\(beforeWrite) serialAfter=\(pasteboard.changeCount) ownerAfter=\(Self.ownerDescription(pasteboard.selectionOwnerWindowID))"
    )
    if !writeObserved {
      Self.logger.notice("write propagation: proceeding to paste anyway (best effort)")
    }

    let pastePosted = poster.post(KeyChord(modifiers: .control, character: "v"))
    Self.logger.notice("paste keystroke: posted=\(pastePosted)")
    guard pastePosted else {
      Self.logger.notice("outcome=noMatch reason=pastePostFailed")
      return .noMatch
    }
    try? await Task.sleep(for: Self.pasteSettle)
    // T-SHELLHELPER-TIMEOUT1: a paste keystroke landing is NOT the same
    // fact as the target app receiving the snippet body — if the write
    // above was never confirmed, the target most likely just pasted back
    // whatever was on the clipboard BEFORE this transaction's write (the
    // just-copied selection itself, in the common case, which is exactly
    // why this failure mode is invisible to the eye: pasting a selection
    // back over itself looks like nothing happened, not like an error).
    // Reporting `.replaced` here regardless of `writeObserved` was the
    // dishonest-success bug this task fixed: the transaction claimed it
    // worked while the clipboard may never have changed. `.writeUnconfirmed`
    // makes that distinction reach the caller — `SnippetExpander.expand()`'s
    // existing `if result != .replaced { beep() }` already treats it as a
    // failure with no further change needed there.
    guard writeObserved else {
      Self.logger.notice("outcome=writeUnconfirmed reason=clipboardWriteNeverConfirmedBeforePaste")
      return .writeUnconfirmed
    }
    Self.logger.notice("outcome=replaced")
    return .replaced
  }

  /// `Self.copyMaxWait`'s `Duration` as a plain `Double` of seconds, purely
  /// so the log line above can report the ceiling without pulling in
  /// `Duration`'s (non-trivial) string interpolation — matches
  /// `X11ClipboardConnection`'s own `ProcessInfo.processInfo.systemUptime`-
  /// based elapsed-time convention (`TimeInterval`, seconds) rather than
  /// introducing a second timing API into this module.
  private static var copyMaxWaitSeconds: Double {
    let components = copyMaxWait.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  // MARK: - Metadata-only diagnostics helpers (T-COPYFLAKE1)
  //
  // Every helper below returns a COUNT, a BOOLEAN, or an OS-level
  // identifier. None of them can return clipboard or selection bytes —
  // `isSentinelOnClipboard` reads the clipboard string but collapses it to
  // a single `Bool` before it can reach a log line, and the sentinel it
  // compares against is a fixed literal this class wrote itself.

  /// 1-minute load average, read per transaction so a failure can be
  /// checked against machine contention instead of assumed independent of
  /// it (the 71.4% measurement recorded load per trial for exactly this
  /// reason and ruled contention out; keeping it in the app's own log
  /// means a future measurement does not depend on the harness remembering
  /// to record it).
  private static var loadAverage1: String {
    guard let raw = try? String(contentsOfFile: "/proc/loadavg", encoding: .utf8),
      let first = raw.split(separator: " ").first
    else { return "?" }
    return String(first)
  }

  /// `nil` (X11 `None`, or no X server) renders as `none` rather than an
  /// empty string, so "nobody owns the selection" can never be misread as
  /// a missing log field.
  private static func ownerDescription(_ windowID: UInt64?) -> String {
    windowID.map { "0x" + String($0, radix: 16) } ?? "none"
  }

  /// Renders the compositor's focus answer, distinguishing the three
  /// states that matter: no probe wired (`waylandFocus=unwired`), probe
  /// wired but the extension refused/timed out (`waylandFocus=unavailable`),
  /// and a real answer. Collapsing the middle case into the first would be
  /// the exact "cannot say I do not know" failure coding-standards.md
  /// names.
  private static func focusDescription(_ probe: (() -> ShellFocusedApp?)?) -> String {
    guard let probe else { return "waylandFocus=unwired" }
    guard let focused = probe() else { return "waylandFocus=unavailable" }
    return "waylandFocus=known \(focused.logDescription)"
  }

  /// Whether the clipboard's text slot still holds this class's own copy
  /// sentinel. Returns a `Bool`, never the string it compared.
  private static func isSentinelOnClipboard(_ pasteboard: LinuxPasteboard) -> Bool {
    pasteboard.string(forType: .string) == copySentinelValue
  }

  /// Metadata-only elapsed-time helper — never touches clipboard content.
  /// Mirrors `IncrTransferReassembler`/`X11ClipboardConnection`'s existing
  /// `ProcessInfo.processInfo.systemUptime` elapsed-time convention in this
  /// same module, rather than introducing a second timing mechanism
  /// (`ContinuousClock`) for this one class.
  private static func elapsedMs(since start: TimeInterval) -> Int {
    Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
  }

  /// Writes `text` through the privileged Shell-helper channel when it's
  /// wired and succeeds, falling back to the ordinary `writer.writeString`
  /// otherwise. B1/DRY fix: this exact two-channel pattern used to be
  /// hand-rolled independently at the copy-sentinel write site, the
  /// expansion-body write site, AND (missing entirely, the B1 bug) the
  /// clipboard-restore site — three chances to drift, and the third one
  /// already had. Every text write this class makes goes through this one
  /// method now. Returns whether the privileged path was used, so callers
  /// that log/branch on it (the two call sites above, and `restoreClipboard`
  /// below) don't have to re-derive it.
  private func writeText(_ text: String) -> Bool {
    let viaPrivileged = privilegedTextWriter?(text) ?? false
    if !viaPrivileged {
      writer.writeString(text, forType: .string)
    }
    return viaPrivileged
  }

  /// Writes `snapshot` back out through whichever `PasteboardWriting` method
  /// matches its representation, so the transaction's transient selection-
  /// copy/expansion-body never survives past this call — the T-BUG1 fix —
  /// and (B1 fix) confirms the write actually reached the clipboard rather
  /// than firing it and hoping.
  ///
  /// `snapshot == nil` covers two cases `LinuxPasteboard.pullRawPayload`
  /// cannot tell apart: the clipboard was genuinely empty, OR it held
  /// privacy-marked (concealed/transient) content that `LinuxPasteboard`
  /// fails closed on and therefore never surfaces through `availableTypes`/
  /// `string(forType:)`/`data(forType:)` in the first place (see that
  /// type's own fail-closed contract) — there is no byte for this replacer
  /// to have captured. Unlike macOS's `ClipboardSelectionReplacer`, which
  /// snapshots raw `NSPasteboardItem`s below the privacy layer and so can
  /// restore concealed content too, this replacer only ever sees the
  /// clipboard through the same privacy-aware `LinuxPasteboard` every other
  /// Linux capture path uses — restoring a byte sequence it was never
  /// allowed to read is not possible without bypassing that fail-closed
  /// contract, which is out of this type's scope. The best available
  /// recovery in that case is clearing the transaction's own leftover text
  /// via the smallest "clear" `PasteboardWriting` exposes (an empty-string
  /// write) rather than leaving the copied selection or expansion body
  /// sitting on the clipboard indefinitely.
  ///
  /// **B1 fix (user-facing data loss):** the `.plainText`/`nil` cases used
  /// to call `writer.writeString` directly — the exact GDK channel
  /// `privilegedTextWriter`'s own doc comment proves silently no-ops for
  /// this class's unfocused background call site (T-SNIPPET-FF1). Once
  /// T-COPYFLAKE1 started writing a sentinel onto the clipboard before
  /// every transaction, a failed copy left that sentinel as the LAST thing
  /// written — so this exact silent no-op stranded
  /// `CLIPNEST_COPY_SENTINEL_7f3a1c9e` in the user's clipboard instead of
  /// their original content, a regression this class's own doc comment
  /// promises never happens. Routing through `writeText(_:)` — the same
  /// privileged-then-ordinary pair the sentinel and expansion-body writes
  /// already use — closes it: whenever the Shell extension is active (the
  /// same condition that makes the sentinel/body writes reliable from this
  /// call site), the restore is now equally reliable. `.file`/`.image`/
  /// `.richText` have no privileged counterpart (`ShellHelperClient
  /// .setClipboardText` is plain-text only) and are unchanged — those types
  /// were never part of the B1 regression, since the sentinel is always a
  /// plain-text write.
  ///
  /// Confirmation: every restore now polls `pasteboard.changeCount` (the
  /// same event-count wait already used to confirm Clipnest's own sentinel/
  /// body writes) and logs whether it landed. A confirmed machine-readable
  /// failure here means the residual case this fix can't close — no Shell
  /// extension AND the ordinary write also silently no-ops for this
  /// background call site — actually occurred; that is now a loud
  /// `.error` log line instead of the silent, invisible stranding B1
  /// reported, even though this method still can't do anything more about
  /// it than the write it already attempted (there is no third channel to
  /// fall back to).
  private func restoreClipboard(_ snapshot: PasteboardReader.RawPayload?) async {
    let beforeRestore = pasteboard.changeCount
    let viaShellHelper: Bool
    switch snapshot {
    case .file(let urlString):
      guard let url = URL(string: urlString) else { return }
      writer.writeFileURL(url)
      viaShellHelper = false
    case .image(let data):
      writer.writeData(data, forType: .png)
      viaShellHelper = false
    case .richText(let rtf, let fallbackPlainText):
      writer.writeRichText(rtf: rtf, plain: fallbackPlainText ?? "")
      viaShellHelper = false
    case .plainText(let text):
      viaShellHelper = writeText(text)
    case nil:
      viaShellHelper = writeText("")
    }
    let restoreWait = await waitForChange(after: beforeRestore)
    Self.logger.notice(
      "clipboard restore: viaShellHelper=\(viaShellHelper) confirmed=\(restoreWait.satisfied) pollTicks=\(restoreWait.ticks) serialBefore=\(beforeRestore) serialAfter=\(pasteboard.changeCount)"
    )
    if !restoreWait.satisfied {
      // B1 fix: make a failed restore VISIBLE rather than silent — this is
      // exactly the failure mode that stranded the copy sentinel in the
      // user's clipboard with no trace anywhere. Still just a log line
      // (there is no fourth channel to retry through), but a loud one:
      // this is user-facing data loss if it fires, never routine.
      Self.logger.error(
        "clipboard restore: FAILED TO CONFIRM — the transaction's transient clipboard content (copy sentinel or expansion body) may still be on the user's clipboard instead of their original content"
      )
    }
  }

  /// Event-count wait: polls `pasteboard.changeCount`
  /// (`X11ClipboardConnection.changeSerial`) for "advanced past `before`".
  /// Used for confirming CLIPNEST'S OWN writes (the copy sentinel, the
  /// expansion-body write, and — B1 fix — the clipboard-restore write) —
  /// see the copy-sentinel comment at this class's main call site for why a
  /// write Clipnest itself controls does not carry the same event/
  /// write-count asymmetry risk a third-party app's copy does, and is also
  /// the fallback for the copy step itself when the sentinel's own landing
  /// can't be confirmed via content (see `sentinelReadBack`).
  private func waitForChange(after before: Int) async -> PollOutcome {
    await pollUntilCeiling { pasteboard.changeCount != before }
  }

  /// Content-comparison wait (T-COPYFLAKE1 fix): polls
  /// `pasteboard.string(forType: .string)` for "no longer equals
  /// `sentinel`" — see this class's main call site for the full root-cause
  /// writeup. Strictly a superset of what the event-count wait can detect:
  /// any real content change trips it, independent of whether mutter's X11
  /// bridge happened to fire a fresh `XFixesSelectionNotify` for that
  /// specific change.
  private func waitForSentinelToClear(_ sentinel: String) async -> PollOutcome {
    await pollUntilCeiling { pasteboard.string(forType: .string) != sentinel }
  }

  /// Shared poll loop for both wait strategies above — same step/ceiling
  /// constants, same "check once more after the ceiling in case the last
  /// sleep landed exactly on the change" shape either one needs; only the
  /// condition itself differs between an opaque counter and real content.
  private func pollUntilCeiling(_ condition: () -> Bool) async -> PollOutcome {
    var waited = Duration.zero
    var ticks = 0
    while waited < Self.copyMaxWait {
      ticks += 1
      if condition() { return PollOutcome(satisfied: true, ticks: ticks) }
      try? await Task.sleep(for: Self.copyWaitStep)
      waited += Self.copyWaitStep
    }
    ticks += 1
    return PollOutcome(satisfied: condition(), ticks: ticks)
  }

  /// `pollUntilCeiling`'s result. The tick COUNT is carried alongside the
  /// verdict (rather than the verdict alone, as before) because a wait that
  /// fails on tick 1 and a wait that fails on tick 34 are different events
  /// — the first means the condition was evaluated once against a stale
  /// read, the second means a full ceiling genuinely elapsed — and the
  /// elapsed-ms figure alone cannot distinguish them if a single poll
  /// iteration itself blocks (an `XConvertSelection` round trip can).
  private struct PollOutcome {
    let satisfied: Bool
    let ticks: Int
  }
}
