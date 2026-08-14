import AppKit
import Foundation
import os

/// Backs the global snippet-expansion hotkey (⌥⌘E): reads the current
/// selection, looks it up as a snippet keyword, and replaces the selection
/// with the snippet body on a match. No match / no selection → a system beep.
///
/// Works in ANY application via a two-strategy approach:
///  1. **Accessibility first** (`SelectedTextAccessing`): reads and replaces
///     the selection directly, WITHOUT touching the clipboard. Used wherever
///     it works — native / most Cocoa text (TextEdit, Notes, Safari fields).
///  2. **Clipboard fallback** (`SelectionReplacing`): when AX can't read the
///     selection (Electron/Chrome/Java apps don't expose it), synthesize
///     copy/paste — which every app supports — snapshotting and RESTORING the
///     clipboard around it so it ends up unchanged. This is the universal,
///     foolproof path; the clipboard is only borrowed when AX can't do it.
///
/// The concrete implementations (`AXSelectedTextAccessor`,
/// `ClipboardSelectionReplacer`) live in the app target; both are injected so
/// `ClipnestCore` never references app-only types, mirroring `Paster`'s
/// protocol-in-Core / concrete-impl-in-app split.
///
/// `@MainActor`: `expand()` drives the Accessibility API, `NSPasteboard`, key
/// synthesis, and `NSSound.beep()` — all main-thread work — so the whole class
/// is main-actor-isolated (callers get a plain, non-`unsafe` stored property).
@MainActor
public final class SnippetExpander {
  private static let logger = Logger(subsystem: ClipnestLog.subsystem, category: "SnippetExpander")

  private let snippetStore: any SnippetStore
  private let selectedText: any SelectedTextAccessing
  private let clipboardReplacer: any SelectionReplacing
  private let beep: () -> Void

  public init(
    snippetStore: any SnippetStore,
    selectedText: any SelectedTextAccessing,
    clipboardReplacer: any SelectionReplacing,
    beep: @escaping () -> Void = { NSSound.beep() }
  ) {
    self.snippetStore = snippetStore
    self.selectedText = selectedText
    self.clipboardReplacer = clipboardReplacer
    self.beep = beep
  }

  /// The snippet body for a given selection, or `nil` if it matches nothing —
  /// shared by both strategies. Trimmed/case-folded matching lives in
  /// `SnippetStore.findByKeyword`.
  private func body(for selection: String) async -> String? {
    do {
      return try await snippetStore.findByKeyword(selection)?.body
    } catch {
      Self.logger.error("findByKeyword failed: \(String(describing: error))")
      return nil
    }
  }

  /// Reads the current selection and replaces it with the matched snippet
  /// body; beeps if nothing was selected or nothing matched.
  public func expand() async {
    // 1) Accessibility path — no clipboard side effect where it works.
    if let selection = selectedText.readSelectedText(),
      !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      guard let snippetBody = await body(for: selection) else {
        // AX read succeeded, so the keyword is real — a clipboard re-read
        // would yield the same non-match. Beep and stop.
        beep()
        return
      }
      if selectedText.replaceSelectedText(with: snippetBody) {
        return
      }
      // AX read worked but the write was refused — fall through to the
      // clipboard path, which pastes the body via a synthesized ⌘V.
    }

    // 2) Clipboard fallback — works in ANY app (Electron/Chrome/etc.), and
    // restores the clipboard afterward. Reached when AX couldn't read the
    // selection at all, or read it but couldn't write.
    let result = await clipboardReplacer.replaceSelection(
      bodyForSelection: { await self.body(for: $0) })
    if result != .replaced {
      beep()
    }
  }
}
