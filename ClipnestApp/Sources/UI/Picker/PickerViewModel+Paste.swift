// PickerViewModel+Paste.swift
//
// M-4 extraction (reviewer finding — `PickerViewModel.swift` carried too
// many responsibilities): pure code motion, zero behavior change. This is
// the pasteboard/paste-orchestration cluster that used to live inline in
// `PickerViewModel.swift` — mapping a `ClipItem`/`Snippet` to the
// `PasteContent` `Paster` should write/paste, then dismissing the panel and
// invoking `Paster` with the "dismiss-before-paste" ordering `pasteAndDismiss`
// documents below (unchanged). Moved here verbatim, same type (`extension
// PickerViewModel`, so still `@MainActor`), same access levels on every
// symbol that already existed, EXCEPT four pre-existing dependencies this
// code needs that are declared in `PickerViewModel.swift`'s own body
// (`blobStore`, `paster`, `frontmostAppTracker`, `pasteboard` — all `let`,
// plus the `static let logger`): those were `private`, which is file-scoped
// in Swift and therefore inaccessible from an extension declared in a
// different file. `blobStore` was already `internal` (ItemRow already reads
// it for thumbnails) and needed no change. `paster`/`frontmostAppTracker`/
// `pasteboard`/`logger` are widened to plain `internal` here — see each
// one's doc comment in `PickerViewModel.swift` for the same note. All four
// are still used ONLY from this file and (for `logger` only) a handful of
// other mutation methods that stay in `PickerViewModel.swift` (`togglePin`,
// `delete`, the Snippets CRUD methods) — nothing outside `PickerViewModel`
// itself touches them; the widening is a compile-time consequence of the
// file split, not a new capability anything else in the app actually uses.
// See `PickerViewModel.swift`'s top doc comment for the file's full design
// history.
import ClipnestCore
import Foundation

extension PickerViewModel {

  // MARK: - Selecting / pasting

  /// T12/T16/T21: selecting a row pastes its content — via `Paster`, which
  /// writes the pasteboard and, only if Accessibility is granted, also
  /// synthesizes ⌘V into the app that was frontmost when the picker opened
  /// — then dismisses the panel. Supports `.text`/`.link`/`.image`/`.file`/
  /// `.richText` via `pasteContent(for:plainText:)`. `plainText` (default
  /// `false`, i.e. rich) is "paste without formatting" (routed follow-up,
  /// rich-paste-preview-snippet-expansion): `true` strips any text-bearing
  /// kind down to its plain `previewText` instead of the richer form.
  func select(_ item: ClipItem, plainText: Bool = false) {
    guard let content = pasteContent(for: item, plainText: plainText) else { return }
    pasteAndDismiss(content)
  }

  /// Maps `item` to the `PasteContent` `Paster` should write/paste, per its
  /// `ItemKind` and `plainText`. When `plainText` is `true`, every text-
  /// bearing kind (`.text`/`.link`/`.richText`) pastes its plain
  /// `previewText`, ignoring any richer stored form — `.image`/`.file` have
  /// no plain form, so they fall through to their normal handling below
  /// unaffected. Otherwise: `.text`/`.link` paste their `previewText`
  /// verbatim (both store their *full* content there). `.richText` reads
  /// its stored RTF blob via `blobPath` and pastes rich; a legacy
  /// `.richText` item captured before RTF was stored has no blob and falls
  /// back to plain `previewText` rather than no-op. `.image` reads its
  /// bytes from `BlobStore` via `blobPath`. `.file` re-offers the original
  /// file via `fileReference`.
  // Deliberately not `private` (unlike everything else in this file's
  // "Selecting" section): `@testable import` only elevates `internal`
  // symbols to be visible outside the module, never `private`/
  // `fileprivate` ones — a `private` `pasteContent` would be permanently
  // unreachable from `ClipnestAppTests` regardless of `@testable import`.
  // This is the exact pure decision logic the architecture/implementation
  // reviews flagged as untested (plain vs. formatted paste), so it's
  // widened to the module's default `internal` access — still invisible
  // outside `ClipnestApp`, just no longer invisible to this module's own
  // test target. See `PickerViewModelTests.swift`.
  func pasteContent(for item: ClipItem, plainText: Bool) -> PasteContent? {
    if plainText {
      // Strip: paste the plain form for any text-bearing kind.
      switch item.kind {
      case .text, .link, .richText:
        return .text(item.previewText)
      case .image, .file:
        break  // no plain form — fall through to normal handling below
      }
    }

    switch item.kind {
    case .text, .link:
      return .text(item.previewText)
    case .richText:
      // Rich by default: read the stored RTF blob. Legacy richText items
      // captured before RTF was stored have no blob → paste the plain
      // previewText rather than no-op.
      guard let blobPath = item.blobPath else { return .text(item.previewText) }
      do {
        let rtf = try blobStore.read(blobPath: blobPath)
        return .richText(rtf: rtf, plain: item.previewText)
      } catch {
        Self.logger.error(
          "Failed to load RTF blob for paste (item \(item.id, privacy: .public)): \(String(describing: error))"
        )
        return .text(item.previewText)
      }
    case .image:
      guard let blobPath = item.blobPath else { return nil }
      do {
        return .image(try blobStore.read(blobPath: blobPath))
      } catch {
        // A missing/corrupt blob means this select silently no-ops (no safe
        // content to paste) rather than crashing. Logged — metadata only,
        // never blob bytes, per coding-standards.md's "never log clipboard
        // content".
        Self.logger.error(
          "Failed to load image blob for paste (item \(item.id, privacy: .public)): \(String(describing: error))"
        )
        return nil
      }
    case .file:
      guard let fileReference = item.fileReference, let url = URL(string: fileReference) else {
        return nil
      }
      return .file(url)
    }
  }

  /// T23: selecting a snippet pastes its `body` through the exact same path
  /// `select(_:)` uses for History/Pinned items — see `pasteAndDismiss(_:)`.
  func pasteSnippet(_ snippet: Snippet) {
    pasteAndDismiss(.text(snippet.body))
  }

  /// Shared by `select(_:)` and `pasteSnippet(_:)`: dismisses the panel
  /// *first*, then writes `content` through `Paster` and tells the running
  /// `ClipboardMonitor` to ignore the resulting self-write.
  ///
  /// **Dismiss-before-paste is deliberate, not incidental ordering**:
  /// `Paster`'s real `CGEventSynthesizer` posts the synthesized ⌘V through
  /// the *global* HID event tap after a short `synthesisDelay`. If
  /// Clipnest's own panel still held key focus when that posts, the OS
  /// could deliver the synthetic keystroke to *our* search field instead of
  /// the previously-frontmost app. Calling `dismiss()` here, before
  /// `Paster` even starts its delay, gives the OS the full `synthesisDelay`
  /// window to hand focus back to that app first.
  private func pasteAndDismiss(_ content: PasteContent) {
    let frontmostApp = frontmostAppTracker.consume()
    dismiss()
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.paster.paste(content, targetingFrontmostApp: frontmostApp)
      } catch {
        // A genuine `PasteError` — the pasteboard write already happened
        // before this could be thrown, so the item is still on the
        // clipboard; this is not fatal. Log metadata only.
        Self.logger.error("Paster failed to synthesize paste: \(String(describing: error))")
      }
      // Must run right after Paster's pasteboard write is observable, before
      // anything else observes the pasteboard — see
      // `suppressOwnPasteboardWrite`'s doc comment.
      self.suppressOwnPasteboardWrite(self.pasteboard.changeCount)
    }
  }
}
