// ItemRow.swift
//
// Plan task T11: a single row in the picker's History list — kind icon,
// preview text, relative timestamp. T12 wired click-to-select via
// `onSelect` rather than baking selection into the row directly.
//
// Plan task T24: pin/unpin + delete row actions, exposed both as a
// right-click context menu and as two always-visible trailing icon
// buttons. `onSelect` is deliberately an `.onTapGesture` (not a wrapping
// `Button`) so the pin/delete `Button`s below can be genuine sibling
// controls in the same row instead of buttons nested inside a button —
// SwiftUI doesn't reliably route taps to an inner control when it's nested
// inside another tappable `Button`'s label.
//
// T24 UI refinement (2026-08-10): the trailing controls are now exactly two
// always-visible icon buttons — pin toggle (icon itself doubles as the
// pinned-state indicator: outline `pin` vs filled `pin.fill`) and delete —
// dark grey at rest, lighter on hover of that specific button. The earlier
// separate pin badge and the separate hover-revealed unpin (`pin.slash`)
// button are both gone; the pin button's own icon is now the only pinned
// indicator.
//
// T23 fix round: added "Save as Snippet" to the context menu only (not a
// third always-visible icon button — T24's UI refinement deliberately
// fixed the trailing controls at exactly two; adding a third here would
// contradict that explicit prior instruction). `query` drives search-match
// highlighting on `previewText` via `HighlightedText` (item 5).
//
// T42 (2026-08-10): reversed the T23 restriction above — the trailing
// controls are now three always-visible icon buttons (pin/unpin, convert to
// snippet, delete). The new middle button reuses the exact same
// `onSaveAsSnippet` action and `supportsSaveAsSnippet` gating the context
// menu's "Save as Snippet" item already had; a `.richText`/`.image`/`.file`
// row still shows only two buttons (pin, delete) since there's no dead
// button rendered for kinds that don't support it.
//
// Rich per-kind previews: the leading slot used to be a fixed SF Symbol for
// every kind (`Self.iconName(for:)`). `.image`/`.file` rows now render an
// actual thumbnail (`ItemIconThumbnail`, below) — the item's captured image
// bytes via `BlobStore`, or the real file icon via `NSWorkspace` — falling
// back to the same plain icon as before while loading or on failure.
// `.link` rows also get distinct title-line styling (accent color +
// underline) so a link is visually distinguishable from plain text at a
// glance, not just by its icon. `.text`/`.richText` are unchanged.
//
// Routed follow-up (2026-08-10): the three trailing row actions (pin,
// convert-to-snippet, delete) now use `ExpandingIconButton` (see
// `UI/Components/ExpandingIconButton.swift`) instead of the old,
// icon-only `RowActionButton` (now deleted — this file was its last
// caller alongside `SnippetRow.swift`, migrated in the same pass; see
// that file's own note). Each button reveals its label (Pin/Unpin, Save
// as Snippet, Delete) sliding in next to the icon on hover instead of
// relying solely on the `.help` tooltip — same interaction the type-filter
// chips got first. `isActive` is left at its default `false` for all
// three: none of these is a "selected among alternatives" control the way
// a filter chip is — pinned state keeps communicating itself exactly as
// before, via the icon glyph alone (`pin` vs `pin.fill`) plus the dynamic
// title, not via `ExpandingIconButton`'s active-tint styling. Row height
// is unaffected — `ExpandingIconButton` pins its own height to a fixed
// 22pt, well under the two-line text block that already determines this
// row's height.
//
// Task 12 (item preview, 2026-08-11): added `onHover`, reporting pointer
// enter/leave on the row's whole `.contentShape(Rectangle())` (same hit
// area `.onTapGesture` already uses) to `PickerView`, which forwards it to
// `PickerViewModel.hoverItem(_:)` — drives which row's `ItemPreview` shows
// beside the picker (`ItemPreviewController`), with hover winning over
// keyboard selection.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI
import UniformTypeIdentifiers

/// Renders one `ClipItem`: a kind-specific leading icon/thumbnail, its
/// `previewText` (single line, truncated, with search matches highlighted),
/// a relative "time ago" timestamp, and three always-visible trailing
/// actions (pin/unpin, convert to snippet, delete) plus a right-click
/// context menu offering those same three actions.
struct ItemRow: View {
  let item: ClipItem
  /// The active search query, for match highlighting (`HighlightedText`) —
  /// empty when there's no active search, in which case this renders
  /// exactly as plain text.
  let query: String
  /// Used by `ItemIconThumbnail` to load `.image` rows' thumbnail bytes.
  let blobStore: BlobStore
  let onSelect: () -> Void
  let onTogglePin: () -> Void
  let onSaveAsSnippet: () -> Void
  let onDelete: () -> Void
  /// T-OCR2: context-menu-only action, only offered `if hasRecognizedText`
  /// — copies the item's OCR text without selecting/pasting the row. See
  /// `PickerViewModel.copyRecognizedText(from:)`.
  let onCopyRecognizedText: () -> Void
  /// T12: reports pointer hover state to `PickerViewModel.hoverItem(_:)` —
  /// `true` when the pointer enters the row, `false` when it leaves. Drives
  /// the preview surface (hover wins over keyboard selection, see that
  /// method's doc comment).
  let onHover: (Bool) -> Void

  /// T-SET4: promoted to `ClipItem.supportsSaveAsSnippet` (Core) — the exact
  /// same predicate `PickerViewModel.presentSaveAsSnippetForm(from:)`/
  /// `saveHighlightedAsSnippet()` and `ShortcutHints`'s footer ⌘S hint now
  /// also read, instead of three independently-written copies. Hiding the
  /// menu item/button here avoids offering an action that would silently
  /// no-op for `.richText`/`.image`/`.file`.

  /// T-OCR2: whether this `.image` row has on-device-recognized text —
  /// drives both the small `text.viewfinder` badge on the thumbnail and
  /// whether "Copy Recognized Text" appears in the context menu. Forwards
  /// to `ClipItem.hasRecognizedText` (T-SET2) — the picker footer's ⌥⏎ hint
  /// needs the exact same test, so the `kind == .image && !(ocrText ?? "")
  /// .isEmpty` predicate is defined exactly once there, not duplicated here.
  private var hasRecognizedText: Bool {
    item.hasRecognizedText
  }

  var body: some View {
    HStack(spacing: 10) {
      leadingContent

      VStack(alignment: .leading, spacing: 2) {
        HighlightedText(text: item.previewText, query: query)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(item.kind == .link ? Color.accentColor : Color.primary)
          .underline(item.kind == .link)

        Text(item.createdAt, format: .relative(presentation: .named))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      rowActions
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .onHover { onHover($0) }
    .contextMenu {
      Button(
        item.pinned ? "Unpin" : "Pin",
        systemImage: item.pinned ? "pin.slash" : "pin",
        action: onTogglePin
      )
      if item.supportsSaveAsSnippet {
        Button("Save as Snippet", systemImage: "text.badge.plus", action: onSaveAsSnippet)
      }
      if hasRecognizedText {
        Button("Copy Recognized Text", systemImage: "text.viewfinder", action: onCopyRecognizedText)
      }
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }

  /// Up to three always-visible trailing actions. The pin button's icon
  /// alone communicates pinned state (`pin.fill` vs `pin`) — there's no
  /// separate badge anymore. The convert-to-snippet button only renders
  /// `if item.supportsSaveAsSnippet`, so a `.richText`/`.image`/`.file` row
  /// shows exactly two buttons (pin, delete) rather than a third that would
  /// silently no-op.
  private var rowActions: some View {
    HStack(spacing: 8) {
      ExpandingIconButton(
        systemName: item.pinned ? "pin.fill" : "pin",
        title: item.pinned ? "Unpin" : "Pin",
        action: onTogglePin
      )
      if item.supportsSaveAsSnippet {
        ExpandingIconButton(
          systemName: "text.badge.plus", title: "Save as Snippet", action: onSaveAsSnippet)
      }
      ExpandingIconButton(systemName: "trash", title: "Delete", action: onDelete)
    }
  }

  /// The leading-edge slot: a real thumbnail for `.image`/`.file` (async-
  /// loaded, see `ItemIconThumbnail`), unchanged plain SF Symbol icons for
  /// `.text`/`.richText`/`.link`. `@ViewBuilder` since the cases return
  /// different concrete view types.
  ///
  /// T-OCR2: an `.image` row with recognized text gets a small
  /// `text.viewfinder` badge overlaid on its thumbnail's bottom-trailing
  /// corner — purely an indicator (not a fourth always-visible button; the
  /// row's three trailing buttons stay exactly pin/save/delete, see
  /// `rowActions`'s doc comment). Tapping it does nothing special — the
  /// badge only signals "this image has recognized text"; copying it lives
  /// in the context menu (`onCopyRecognizedText`) and ⌥⏎ (see
  /// `PickerViewModel.pasteContent(for:plainText:)`).
  @ViewBuilder
  private var leadingContent: some View {
    switch item.kind {
    case .image:
      ItemIconThumbnail(
        item: item, blobStore: blobStore, fallbackSystemImage: item.kind.sfSymbolName
      )
      .overlay(alignment: .bottomTrailing) {
        if hasRecognizedText {
          Image(systemName: "text.viewfinder")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .padding(2)
            .background(Circle().fill(Color.accentColor))
            .offset(x: 3, y: 3)
            .help("Contains recognized text")
        }
      }
    case .file:
      ItemIconThumbnail(
        item: item, blobStore: blobStore, fallbackSystemImage: item.kind.sfSymbolName)
    case .text, .richText, .link:
      Image(systemName: item.kind.sfSymbolName)
        .foregroundStyle(.secondary)
        .frame(width: 18)
    }
  }
}

/// Async-loads and caches a small leading-edge thumbnail for `.image` (via
/// `BlobStore`) and `.file` (via `NSWorkspace`'s file icon) rows, falling
/// back to the plain SF Symbol icon `ItemRow` used before this task while
/// loading or on any failure (missing blob, deleted file, undecodable
/// bytes) — never blocks row rendering: the actual FILE READ happens off
/// the main thread inside `.task`, which SwiftUI cancels automatically if
/// the row disappears before it finishes (e.g. fast scrolling).
///
/// T-PF3 (P0 image-hang fix), D1: an earlier version of this comment also
/// claimed the *decode* happened off the main thread here — it did not.
/// `NSImage(data:)` only reads the bytes eagerly; it DEFERS pixel decode to
/// draw time, so the actual decode of a full-resolution ~25 MB screenshot
/// TIFF was happening on the main/render thread just to draw this 20pt
/// icon. `load()` now calls `ImageThumbnailDecoder.decode(_:maxPixelSize:)`
/// (ImageIO's `CGImageSourceCreateThumbnailAtIndex`), which decodes
/// straight to a bitmap sized for `Self.rowThumbnailMaxPixelSize` — the
/// decode cost is now bounded by the 20pt display size, not the source
/// image's resolution, and it happens entirely inside this `.task`, off the
/// main thread.
private struct ItemIconThumbnail: View {
  let item: ClipItem
  let blobStore: BlobStore
  let fallbackSystemImage: String

  /// Longer edge, in pixels, that a row thumbnail is decoded to.
  /// macOS's maximum display backing scale is 2x (there are no 3x/Retina-HD
  /// displays on macOS the way there are on iOS), so 2x of the 20pt frame
  /// (40px) would already be enough — 64 adds headroom for the `.fill`
  /// aspect crop (which can sample slightly more than the exact frame) at a
  /// negligible memory cost (64×64×4 bytes ≈ 16 KB per thumbnail).
  ///
  /// `nonisolated`: `ItemIconThumbnail` (a `View`) is implicitly
  /// `@MainActor`, but this is a plain constant read from `load()`'s
  /// `Task.detached` background decode — a global-actor-isolated stored
  /// property can't be read from a `nonisolated`/detached context, and this
  /// value carries no actor-isolated state, so opting it out is safe.
  nonisolated static let rowThumbnailMaxPixelSize = 64

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 20, height: 20)
          .clipShape(RoundedRectangle(cornerRadius: 3))
      } else {
        Image(systemName: fallbackSystemImage)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 18)
    .task(id: cacheKey) {
      await load()
    }
  }

  /// What identifies "the same thumbnail" across re-renders — `blobPath`
  /// for `.image`, `fileReference` for `.file`. `.task(id:)` re-runs the
  /// load only when this changes, so a row that's re-rendered for an
  /// unrelated reason (e.g. a live-refresh poll) doesn't reload/redecode
  /// bytes it already has.
  private var cacheKey: String? {
    item.kind == .image ? item.blobPath : item.fileReference
  }

  private func load() async {
    guard let cacheKey else { return }
    if let cached = ItemThumbnailCache.row.image(for: cacheKey) {
      image = cached
      return
    }
    // T-PF3 (P0 image-hang fix), D4: fast-scrolling an image-heavy history
    // can bring dozens of rows on screen within one runloop tick, each
    // reaching this `.task` at roughly the same time. `withPermit` bounds
    // how many of those run their read+decode concurrently instead of
    // letting every visible row race for disk I/O and CPU at once — see
    // `RowThumbnailLoadLimiter`'s doc comment.
    //
    // The actual read+decode, run under the limiter's permit below. Pulled
    // into a local closure purely for readability of the two-step `guard`
    // that follows — see its comment.
    let loadThumbnail: @Sendable () async -> DecodedThumbnail? = {
      await Task.detached(priority: .utility) { () -> DecodedThumbnail? in
        switch item.kind {
        case .image:
          guard let blobPath = item.blobPath, let data = try? blobStore.read(blobPath: blobPath)
          else { return nil }
          return ImageThumbnailDecoder.decode(
            data, maxPixelSize: Self.rowThumbnailMaxPixelSize)
        case .file:
          // Use a GENERIC type icon from the extension — NOT
          // `icon(forFile:)`/`fileExists`, which access the real file on disk
          // and, for TCC-protected folders (Desktop/Documents/Downloads),
          // trigger a permission gate + QuickLook thumbnail generation that
          // froze the app for seconds. `icon(for: UTType)` is a pure type→icon
          // lookup with zero file-system access.
          guard let fileReference = item.fileReference,
            let url = URL(string: fileReference), url.isFileURL
          else { return nil }
          let type = UTType(filenameExtension: url.pathExtension) ?? .data
          let icon = NSWorkspace.shared.icon(for: type)
          return DecodedThumbnail(image: icon, byteCost: Self.approximateByteCost(of: icon))
        case .text, .richText, .link:
          return nil
        }
      }.value
    }

    // Two nested optionals to unwrap here, meaning two different things —
    // both handled the same way (bail without touching the cache or
    // `image`), but worth naming separately:
    //  - the OUTER optional (`permitOutcome`) is `nil` when this
    //    `.task(id:)` was cancelled (row scrolled off-screen/got recycled)
    //    while still queued for a permit — `loadThumbnail` above never ran
    //    at all. See `RowThumbnailLoadLimiter.withPermit`'s doc comment.
    //  - the INNER optional (`loaded`) is `nil` when the load DID run (a
    //    permit was granted) to completion but produced nothing — missing
    //    blob, deleted file, or undecodable bytes, same as before this fix.
    guard let permitOutcome = await RowThumbnailLoadLimiter.shared.withPermit(loadThumbnail)
    else { return }
    guard let loaded = permitOutcome else { return }
    ItemThumbnailCache.row.store(loaded.image, cost: loaded.byteCost, for: cacheKey)
    image = loaded.image
  }

  /// Approximate decoded-bitmap byte cost for an `NSImage` that didn't come
  /// through `ImageThumbnailDecoder` (which computes an exact cost from its
  /// own `CGImage`) — the `.file` case's `NSWorkspace` type icon. Same
  /// 4-bytes/pixel estimate `ImageThumbnailDecoder` uses (T-PF6: both now
  /// derive from `ClipnestCore.RGBAPixelFormat.bytesPerPixel`, the one
  /// shared source for this fact — see that type's doc comment); `NSCache`
  /// only needs a relative cost signal, not an exact byte count.
  /// `nonisolated` for the same reason as `rowThumbnailMaxPixelSize` above —
  /// called from `load()`'s `Task.detached` background closure.
  private nonisolated static func approximateByteCost(of image: NSImage) -> Int {
    max(1, Int(image.size.width * image.size.height) * RGBAPixelFormat.bytesPerPixel)
  }
}
