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
/// `TerminalAppRegistry.modifiers(forAppIdentifier:)` decides Ctrl+C/
/// Ctrl+V vs. Ctrl+Shift+C/Ctrl+Shift+V for BOTH copy and paste from the
/// same terminal-identifier list (a terminal emulator reassigns plain
/// Ctrl+C to SIGINT and plain Ctrl+V to nothing useful, exactly the same
/// reason `Paster`'s own paste chord needs it).
///
/// Snapshots and restores the clipboard around the whole transaction via
/// `GTKClipboardWriting` + the injected pasteboard reader, so the user's
/// clipboard ends up unchanged — same contract as the macOS type. Capture
/// suppression (`beginSuppression`/`endSuppression`) is wired by the
/// composition root to `ClipboardMonitor.pause()`/`ignore(changeCount:)`
/// + `resume()`, mirroring `AppEnvironment`'s wiring exactly.
///
/// Manual-verify only for the actual synthesized keystrokes/clipboard
/// I/O (no display in CI); the terminal-vs-plain chord decision it
/// delegates to is `TerminalAppRegistryTests`' existing coverage.
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
  /// write, tried before the ordinary `writer.writeString` below — see
  /// `ShellHelperClient.setClipboardText`'s doc comment for the full
  /// mechanism and evidence. `writer.writeString` (`gdk_clipboard_set_text`)
  /// silently never takes effect for THIS call site specifically, because
  /// this whole method runs with no Clipnest window ever holding Wayland
  /// keyboard focus (triggered by a background global-hotkey handler, not
  /// a click inside a live Clipnest window) — unlike, say, the picker's
  /// own copy-on-select, which runs from inside a real click on a real,
  /// focused Clipnest window and therefore has a legitimate input serial.
  /// `nil` (the default, and every existing test's setup — no behavior
  /// change for them) falls back to `writer.writeString` exactly as
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
    let transactionStart = ProcessInfo.processInfo.systemUptime
    Self.logger.notice("clipboard-fallback tier: transaction started")

    beginSuppression()
    let snapshot = payloadReader.pullRawPayload(from: pasteboard)
    defer {
      restoreClipboard(snapshot)
      endSuppression()
      Self.logger.notice(
        "clipboard-fallback tier: transaction ended, totalElapsedMs=\(Self.elapsedMs(since: transactionStart))"
      )
    }

    let modifiers = TerminalAppRegistry.modifiers(
      forAppIdentifier: frontmostAppProvider.currentFrontmostAppRef()?.bundleID)
    let isTerminalChord = modifiers == [.control, .shift]
    Self.logger.notice(
      "copy/paste chord: terminalMatch=\(isTerminalChord) (chord=\(isTerminalChord ? "ctrl+shift" : "ctrl"))"
    )

    let before = pasteboard.changeCount
    let copyPostStart = ProcessInfo.processInfo.systemUptime
    let copyPosted = poster.post(KeyChord(modifiers: modifiers, character: "c"))
    Self.logger.notice(
      "copy keystroke: posted=\(copyPosted) elapsedMs=\(Self.elapsedMs(since: copyPostStart))")
    guard copyPosted else {
      Self.logger.notice("outcome=noSelection reason=copyPostFailed")
      return .noSelection
    }

    let waitStart = ProcessInfo.processInfo.systemUptime
    let observedChange = await waitForChange(after: before)
    Self.logger.notice(
      "waitForChange: observedChange=\(observedChange) elapsedMs=\(Self.elapsedMs(since: waitStart)) ceilingMs=\(Int(Self.copyMaxWaitSeconds * 1000))"
    )
    guard observedChange else {
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
    let wroteViaShellHelper = privilegedTextWriter?(body) ?? false
    if !wroteViaShellHelper {
      writer.writeString(body, forType: .string)
    }
    let writeObserved = await waitForChange(after: beforeWrite)
    Self.logger.notice(
      "write propagation: viaShellHelper=\(wroteViaShellHelper) observed=\(writeObserved) elapsedMs=\(Self.elapsedMs(since: writeStart))"
    )
    if !writeObserved {
      Self.logger.notice("write propagation: proceeding to paste anyway (best effort)")
    }

    let pastePosted = poster.post(KeyChord(modifiers: modifiers, character: "v"))
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

  /// Metadata-only elapsed-time helper — never touches clipboard content.
  /// Mirrors `IncrTransferReassembler`/`X11ClipboardConnection`'s existing
  /// `ProcessInfo.processInfo.systemUptime` elapsed-time convention in this
  /// same module, rather than introducing a second timing mechanism
  /// (`ContinuousClock`) for this one class.
  private static func elapsedMs(since start: TimeInterval) -> Int {
    Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
  }

  /// Writes `snapshot` back out through whichever `PasteboardWriting` method
  /// matches its representation, so the transaction's transient selection-
  /// copy/expansion-body never survives past this call — the T-BUG1 fix.
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
  private func restoreClipboard(_ snapshot: PasteboardReader.RawPayload?) {
    switch snapshot {
    case .file(let urlString):
      guard let url = URL(string: urlString) else { return }
      writer.writeFileURL(url)
    case .image(let data):
      writer.writeData(data, forType: .png)
    case .richText(let rtf, let fallbackPlainText):
      writer.writeRichText(rtf: rtf, plain: fallbackPlainText ?? "")
    case .plainText(let text):
      writer.writeString(text, forType: .string)
    case nil:
      writer.writeString("", forType: .string)
    }
  }

  private func waitForChange(after before: Int) async -> Bool {
    var waited = Duration.zero
    while waited < Self.copyMaxWait {
      if pasteboard.changeCount != before { return true }
      try? await Task.sleep(for: Self.copyWaitStep)
      waited += Self.copyWaitStep
    }
    return pasteboard.changeCount != before
  }
}
