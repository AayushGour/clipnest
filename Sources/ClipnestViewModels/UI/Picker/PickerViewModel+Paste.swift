// PickerViewModel+Paste.swift
//
// M-4 extraction (reviewer finding — `PickerViewModel.swift` carried too
// many responsibilities): pure code motion, zero behavior change at the
// time. This is the pasteboard/paste-orchestration cluster that used to
// live inline in `PickerViewModel.swift` — mapping a `ClipItem`/`Snippet` to
// the `PasteContent` `Paster` should write/paste, then dismissing the panel
// and invoking `Paster` with the "dismiss-before-paste" ordering
// `performPaste`'s doc comment below documents. Moved here verbatim, same
// type (`extension PickerViewModel`, so still `@MainActor`), same access
// levels on every symbol that already existed, EXCEPT four pre-existing
// dependencies this code needs that are declared in `PickerViewModel.swift`'s
// own body (`blobStore`, `paster`, `frontmostAppTracker`, `pasteboard` — all
// `let`, plus the `static let logger`): those were `private`, which is
// file-scoped in Swift and therefore inaccessible from an extension declared
// in a different file. `blobStore` was already `internal` (ItemRow already
// reads it for thumbnails) and needed no change. `paster`/`frontmostAppTracker`/
// `pasteboard`/`logger` are widened to plain `internal` here — see each
// one's doc comment in `PickerViewModel.swift` for the same note. All four
// are still used ONLY from this file and (for `logger` only) a handful of
// other mutation methods that stay in `PickerViewModel.swift` (`togglePin`,
// `delete`, the Snippets CRUD methods) — nothing outside `PickerViewModel`
// itself touches them; the widening is a compile-time consequence of the
// file split, not a new capability anything else in the app actually uses.
// See `PickerViewModel.swift`'s top doc comment for the file's full design
// history.
//
// T-PERF1 (2026-09-03, user directive: no heavy work on the main actor):
// `pasteContent(for:plainText:)` became `async` — its `.richText`/`.image`
// blob reads now run off `@MainActor` (`readBlobOffMain`, below) instead of
// synchronously here. `select(_:plainText:)` and `pasteSnippet(_:)` no
// longer funnel through one shared `pasteAndDismiss(_:)` that both captured
// `frontmostApp` and dismissed — `select(_:)` has to resolve `pasteContent`
// FIRST (preserving its "nil content leaves the picker open" behavior, see
// its own doc comment) before it's safe to dismiss, so each caller now
// captures `frontmostApp`/dismisses itself and calls the still-shared
// `performPaste(_:frontmostApp:)` for the write-and-suppress tail. This IS a
// behavior-preserving refactor, not a "no behavior change" one like the
// original M-4 extraction — see `select`'s and `performPaste`'s doc
// comments for exactly what was preserved and why.
// P5 (Phase 3, Linux port): `import AppKit` dropped — this file never used
// an AppKit symbol directly (its `NSPasteboard.PasteboardType` reads were
// always really `ClipMediaType`, already a portable typealias/struct — see
// `ClipnestCore/Clipboard/ClipMediaType.swift`), so this was already
// removable independent of the move.
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
  // T-PERF1: `select` itself stays synchronous (never blocks the caller —
  // it only starts a `Task`), but the content it needs may now require an
  // off-main blob read (`pasteContent(for:plainText:)` is `async` — see its
  // doc comment). The `Task` resolves content FIRST and only THEN captures
  // `frontmostApp`/dismisses, preserving the original synchronous behavior
  // exactly: a nil `content` (missing/corrupt blob) still leaves the picker
  // open with nothing pasted, never a dismiss-then-no-op. This also means
  // `dismiss()` (and therefore `Paster`'s `synthesisDelay` countdown — see
  // `performPaste`'s doc comment) starts a few ms later for blob-backed
  // content than it did when the read was synchronous — strictly SAFER for
  // the "give the OS time to hand focus back before posting ⌘V" invariant,
  // never less safe, since it only pushes the delay's start later, not
  // earlier.
  public func select(_ item: ClipItem, plainText: Bool = false) {
    Task { [weak self] in
      guard let self else { return }
      guard let content = await self.pasteContent(for: item, plainText: plainText) else {
        return
      }
      let frontmostApp = self.frontmostAppTracker.consume()
      self.dismiss()
      await self.performPaste(content, frontmostApp: frontmostApp)
    }
  }

  /// Maps `item` to the `PasteContent` `Paster` should write/paste, per its
  /// `ItemKind` and `plainText`. When `plainText` is `true`, every text-
  /// bearing kind (`.text`/`.link`/`.richText`) pastes its plain
  /// `previewText`, ignoring any richer stored form. `.image` has an
  /// overloaded "plain form" too (T-OCR2): if on-device OCR recognized text
  /// in it (`item.ocrText`, non-empty), `plainText` pastes THAT instead of
  /// the image — the same ⌥⏎ shortcut that already means "paste without
  /// formatting" naturally extends to "paste this image's text" for a
  /// screenshot. An `.image` with no recognized text, and `.file` (which
  /// has no plain form at all), both fall through to their normal handling
  /// below unaffected. Otherwise: `.text`/`.link` paste their `previewText`
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
  // T-PERF1: `async` — `.richText`/`.image` read their bytes from
  // `BlobStore` (`readBlobOffMain`, below), which now runs the actual
  // `Data(contentsOf:)` disk I/O in a detached background task instead of
  // synchronously on this (`@MainActor`) method. Measured ~9ms on the
  // user's largest real captured image; not catastrophic at that size, but
  // exactly the per-paste main-thread work this task exists to eliminate,
  // and unbounded for a larger one. `.text`/`.link`/`.file` do no I/O at
  // all and resolve immediately either way — `async` costs them only a
  // negligible task-hop, not a real suspension.
  func pasteContent(for item: ClipItem, plainText: Bool) async -> PasteContent? {
    if plainText {
      // Strip: paste the plain form for any text-bearing kind.
      switch item.kind {
      case .text, .link, .richText:
        return .text(item.previewText)
      case .image:
        // T-OCR2: an image's "plain form" is its recognized text, when it
        // has one — falls through to the normal `.image` handling below
        // (pastes the image itself) when recognition hasn't run, found
        // nothing, or the setting was off at capture time.
        // Goes through `ClipItem.hasRecognizedText` rather than re-testing
        // `ocrText` inline: that predicate is the single definition of "this
        // image has usable recognized text" (see `ClipItemOCR.swift`), and
        // `ItemRow`/`ShortcutHints` already gate their UI on it. Re-deriving
        // it here would silently diverge the moment that rule changes.
        if item.hasRecognizedText, let ocrText = item.ocrText {
          return .text(ocrText)
        }
      case .file:
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
        let rtf = try await readBlobOffMain(blobPath)
        return .richText(rtf: rtf, plain: item.previewText)
      } catch {
        Self.logger.error(
          "Failed to load RTF blob for paste (item \(item.id)): \(String(describing: error))"
        )
        return .text(item.previewText)
      }
    case .image:
      guard let blobPath = item.blobPath else { return nil }
      do {
        return .image(try await readBlobOffMain(blobPath))
      } catch {
        // A missing/corrupt blob means this select silently no-ops (no safe
        // content to paste) rather than crashing. Logged — metadata only,
        // never blob bytes, per coding-standards.md's "never log clipboard
        // content".
        Self.logger.error(
          "Failed to load image blob for paste (item \(item.id)): \(String(describing: error))"
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

  /// T-PERF1: off-main blob read for the paste path — `BlobStore
  /// .read(blobPath:)` is synchronous `Data(contentsOf:)` disk I/O, which
  /// used to run inline on `pasteContent`'s caller (`@MainActor`, since
  /// `PickerViewModel` is). Mirrors the exact `Task.detached(priority:
  /// .utility)` pattern already used for off-main blob reads elsewhere
  /// (`ItemPreview.AsyncBlobImage`, `ItemRow.load()`,
  /// `ClipboardMonitor.checkNow`'s blob write) — copied into a local `let`
  /// first so the closure captures the `Sendable` `BlobStore` value, not
  /// `self` (`PickerViewModel` itself is `@MainActor`-isolated and not
  /// `Sendable`).
  private func readBlobOffMain(_ blobPath: String) async throws -> Data {
    let blobStore = self.blobStore
    return try await Task.detached(priority: .utility) {
      try blobStore.read(blobPath: blobPath)
    }.value
  }

  /// T23: selecting a snippet pastes its `body` through the same
  /// dismiss-then-paste path `select(_:)` uses for History/Pinned items —
  /// see `performPaste`'s doc comment. No blob I/O here (a snippet's `body`
  /// is already an in-memory `String`), so — unlike `select(_:)` — there's
  /// no async content resolution to sequence before capturing
  /// `frontmostApp`/dismissing.
  public func pasteSnippet(_ snippet: Snippet) {
    let frontmostApp = frontmostAppTracker.consume()
    dismiss()
    Task { [weak self] in
      guard let self else { return }
      await self.performPaste(.text(snippet.body), frontmostApp: frontmostApp)
    }
  }

  /// T-OCR2: `ItemRow`'s "Copy Recognized Text" context-menu action —
  /// writes `item.ocrText` straight to the pasteboard WITHOUT dismissing
  /// the picker or synthesizing a paste (unlike `select(_:plainText:)`/
  /// ⌥⏎, which do both). This is a plain "put it on the clipboard" action:
  /// the user keeps browsing and pastes manually wherever they like. A
  /// no-op if `item` has no recognized text — `ItemRow` already only shows
  /// this action when it does (see `ItemRow.hasRecognizedText`), so
  /// reaching here with nothing to copy would mean a caller bug, not a
  /// normal path; guarding rather than crashing keeps this safe either way.
  public func copyRecognizedText(from item: ClipItem) {
    guard item.hasRecognizedText, let ocrText = item.ocrText else { return }
    pasteboard.writeString(ocrText, forType: .string)
    // Same self-write suppression every other Clipnest-originated
    // pasteboard write in this file uses — see `performPaste`'s doc
    // comment and `ClipboardMonitor.ignore(changeCount:)` — so this copy
    // never gets recaptured as a new external copy on the monitor's next
    // poll.
    suppressOwnPasteboardWrite(pasteboard.changeCount)
  }

  /// Shared by `select(_:)` and `pasteSnippet(_:)`, called AFTER the caller
  /// has already captured `frontmostApp` and dismissed the panel — writes
  /// `content` through `Paster` and tells the running `ClipboardMonitor` to
  /// ignore the resulting self-write.
  ///
  /// **Dismiss-before-paste is deliberate, not incidental ordering** (why
  /// this is the caller's job, not this method's): `Paster`'s real
  /// `CGEventSynthesizer` posts the synthesized ⌘V through the *global* HID
  /// event tap after a short `synthesisDelay`. If Clipnest's own panel
  /// still held key focus when that posts, the OS could deliver the
  /// synthetic keystroke to *our* search field instead of the
  /// previously-frontmost app. The caller dismissing before calling this,
  /// before `Paster` even starts its delay, gives the OS the full
  /// `synthesisDelay` window to hand focus back to that app first.
  ///
  /// T-HANG2 (fixed a real, quantified race — see `Paster.paste`'s doc
  /// comment for the full story): this used to call
  /// `suppressOwnPasteboardWrite` itself, AFTER `paster.paste(...)` had
  /// FULLY returned — i.e. after `synthesisDelay` (40ms default) plus a
  /// real event post had already elapsed since the write. T-STRESS1's
  /// harness quantified that window and showed the 0.4s capture poll
  /// landing inside it in production (18/18 raced at 5-42ms; worse for
  /// `.image` content — a genuinely new duplicate row + wasted blob, not
  /// just a bumped `createdAt`). Now `suppressOwnPasteboardWrite` is passed
  /// straight through as `Paster.paste`'s `onPasteboardWrite` callback, so
  /// it fires the instant the write is observable — before
  /// `synthesisDelay`'s sleep even starts — closing that window down to
  /// essentially a single `@MainActor` hop instead of 40ms+.
  private func performPaste(_ content: PasteContent, frontmostApp: FrontmostAppRef?) async {
    do {
      try await paster.paste(
        content, targetingFrontmostApp: frontmostApp,
        onPasteboardWrite: { [weak self] changeCount in
          self?.suppressOwnPasteboardWrite(changeCount)
        })
    } catch {
      // A genuine `PasteError` — the pasteboard write (and therefore
      // `onPasteboardWrite`/suppression) already happened before this could
      // be thrown, so the item is still on the clipboard and correctly
      // self-write-suppressed; this is not fatal. Log metadata only.
      Self.logger.error("Paster failed to synthesize paste: \(String(describing: error))")
    }
  }
}
