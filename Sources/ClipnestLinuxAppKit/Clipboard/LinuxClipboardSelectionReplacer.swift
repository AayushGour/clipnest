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

  public var beginSuppression: () -> Void = {}
  public var endSuppression: () -> Void = {}

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
    beginSuppression()
    let snapshot = payloadReader.pullRawPayload(from: pasteboard)
    defer {
      restoreClipboard(snapshot)
      endSuppression()
    }

    let modifiers = TerminalAppRegistry.modifiers(
      forAppIdentifier: frontmostAppProvider.currentFrontmostAppRef()?.bundleID)

    let before = pasteboard.changeCount
    guard poster.post(KeyChord(modifiers: modifiers, character: "c")),
      await waitForChange(after: before)
    else { return .noSelection }

    let selection = pasteboard.string(forType: .string) ?? ""
    guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .noSelection
    }
    guard let body = await bodyForSelection(selection) else { return .noMatch }

    writer.writeString(body, forType: .string)
    guard poster.post(KeyChord(modifiers: modifiers, character: "v")) else { return .noMatch }
    try? await Task.sleep(for: Self.pasteSettle)
    return .replaced
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
