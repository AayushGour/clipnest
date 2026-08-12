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
  /// T12: reports pointer hover state to `PickerViewModel.hoverItem(_:)` —
  /// `true` when the pointer enters the row, `false` when it leaves. Drives
  /// the preview surface (hover wins over keyboard selection, see that
  /// method's doc comment).
  let onHover: (Bool) -> Void

  /// "Save as Snippet" only makes sense for kinds whose `previewText` is
  /// the item's *full* content (`.text`/`.link`) — same restriction
  /// `PickerViewModel.select(_:)`/`presentSaveAsSnippetForm(from:)` already
  /// enforce; hiding the menu item here avoids offering an action that
  /// would silently no-op for `.richText`/`.image`/`.file`.
  private var supportsSaveAsSnippet: Bool {
    item.kind == .text || item.kind == .link
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
      if supportsSaveAsSnippet {
        Button("Save as Snippet", systemImage: "text.badge.plus", action: onSaveAsSnippet)
      }
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }

  /// Up to three always-visible trailing actions. The pin button's icon
  /// alone communicates pinned state (`pin.fill` vs `pin`) — there's no
  /// separate badge anymore. The convert-to-snippet button only renders
  /// `if supportsSaveAsSnippet`, so a `.richText`/`.image`/`.file` row shows
  /// exactly two buttons (pin, delete) rather than a third that would
  /// silently no-op.
  private var rowActions: some View {
    HStack(spacing: 8) {
      ExpandingIconButton(
        systemName: item.pinned ? "pin.fill" : "pin",
        title: item.pinned ? "Unpin" : "Pin",
        action: onTogglePin
      )
      if supportsSaveAsSnippet {
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
  @ViewBuilder
  private var leadingContent: some View {
    switch item.kind {
    case .image:
      ItemIconThumbnail(
        item: item, blobStore: blobStore, fallbackSystemImage: item.kind.sfSymbolName)
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
/// bytes) — never blocks row rendering: the actual load happens off the
/// main thread inside `.task`, which SwiftUI cancels automatically if the
/// row disappears before it finishes (e.g. fast scrolling).
private struct ItemIconThumbnail: View {
  let item: ClipItem
  let blobStore: BlobStore
  let fallbackSystemImage: String

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
    if let cached = ItemThumbnailCache.shared.image(for: cacheKey) {
      image = cached
      return
    }
    let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
      switch item.kind {
      case .image:
        guard let blobPath = item.blobPath, let data = try? blobStore.read(blobPath: blobPath)
        else { return nil }
        return NSImage(data: data)
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
        return NSWorkspace.shared.icon(for: type)
      case .text, .richText, .link:
        return nil
      }
    }.value
    guard let loaded else { return }
    ItemThumbnailCache.shared.store(loaded, for: cacheKey)
    image = loaded
  }
}
