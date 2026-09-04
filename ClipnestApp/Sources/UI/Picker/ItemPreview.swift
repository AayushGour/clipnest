// ItemPreview.swift
//
// Content of the hover popover (presented by `ItemPreviewController`):
//   - `.text`/`.link`/`.richText` → PLAIN text (`previewText`), scrollable,
//                                    loaded in chunks as you scroll down.
//   - `.image`                    → the actual image (async blob load), up to
//                                    `imageMaxWidth` (40% of the screen width,
//                                    computed by `ItemPreviewController`).
//   - `.file`                     → filename + size + path, all from metadata
//                                    captured at copy time. NO file-system
//                                    access (that TCC gate is what froze the
//                                    picker — the row icon was the culprit and
//                                    is now a generic type icon).
// Has its own material background + rounded corners (the hosting panel is
// transparent) and reports its own hover via `onHover`, so the popover stays
// open while the pointer is over it and can be scrolled.
//
// T-PF3 (P0 image-hang fix), D4: `PickerViewModel+Preview.swift`'s
// `previewShowDelay` doc comment justifies its 20ms hover cadence with
// "content is bounded (text capped, files excluded)". That was true for
// text/file previews but FALSE for `.image` previews — there was no bound
// at all on the decoded image resolution, which is what made a 20ms-cadence
// sweep across an image-heavy history hang. That stale invariant lives in a
// file this task doesn't own (`PickerViewModel+Preview.swift`) so it isn't
// edited here, but flagging it here since this is the file whose actual
// behavior falsified it: `imagePreview`/`AsyncBlobImage` below now decode
// through `ImageThumbnailDecoder` at a bounded `previewImageMaxPixelSize`,
// so image content is bounded too, same as text/files — the invariant is
// restored, just not by editing the comment that stated it.

import AppKit
import ClipnestCore
import SwiftUI

struct ItemPreview: View {
  let item: ClipItem
  let blobStore: BlobStore
  /// Max width/height for the rendered image — 40% of the screen width the
  /// popover is shown on (computed by `ItemPreviewController`). Text uses its
  /// own fixed width (`Self.textMaxWidth`), not this.
  let imageMaxWidth: CGFloat
  /// Reports pointer hover over the popover itself. `ItemPreviewController`
  /// wires this to `PickerViewModel.previewHoverChanged(_:)` so the popover
  /// stays open (and scrollable) while hovered, closing only once the pointer
  /// has left both the row and this popover.
  let onHover: (Bool) -> Void

  private static let textMaxWidth: CGFloat = 380
  private static let textMaxHeight: CGFloat = 360
  /// T-OCR2: cap on the recognized-text section shown below an `.image`
  /// preview — deliberately smaller than `textMaxHeight` (used for a plain
  /// `.text`/`.link`/`.richText` preview, which has no image sharing the
  /// popover with it) so image + recognized text together stay a
  /// reasonable overall popover height.
  private static let ocrTextMaxHeight: CGFloat = 160
  private static let cornerRadius: CGFloat = 10
  /// Padding around this popover's whole content. Not `private`:
  /// `ItemPreviewController.boundedImageContentSize` reads this same
  /// constant to compute the panel's content size analytically for a plain
  /// image (no recognized text) WITHOUT a synchronous SwiftUI layout pass
  /// (see that method's doc comment, T-PF3 D4) — one constant, referenced
  /// from both places, rather than a literal `12` duplicated and liable to
  /// drift out of sync.
  static let contentPadding: CGFloat = 12
  /// Longer edge, in pixels, that a preview image is decoded to
  /// (`ImageThumbnailDecoder`, used by `AsyncBlobImage` below).
  /// `ItemPreviewController.update` caps the DISPLAYED width to at most 40%
  /// of the screen width; even on Apple's widest current display (Pro
  /// Display XDR, ~3008pt wide at its default scaled resolution) that's
  /// roughly 1200pt, ~2400px at a 2x Retina backing. 1600 trades a little
  /// sharpness on that extreme case for meaningfully less memory per cached
  /// preview (see `ItemThumbnailCache.preview`'s cost-limit math) — still
  /// far sharper than any practical window size actually needs, and a small
  /// fraction of a real screenshot's full resolution.
  ///
  /// `nonisolated`: `ItemPreview` (a `View`) is implicitly `@MainActor`, but
  /// this is a plain constant read from `AsyncBlobImage`'s `Task.detached`
  /// background decode — a global-actor-isolated stored property can't be
  /// read from a `nonisolated`/detached context, and this value carries no
  /// actor-isolated state, so opting it out is safe.
  nonisolated static let previewImageMaxPixelSize = 1_600
  /// Size of the "still loading" placeholder box `AsyncBlobImage` shows
  /// before its first decode completes. Not `private`:
  /// `ItemPreviewController.boundedImageContentSize` reads this same
  /// constant as the KNOWN size to use for the very first hover on an image
  /// that isn't cached yet, so the panel's initial size matches exactly
  /// what this view renders at that moment — no `fittingSize` measurement
  /// needed (T-PF3 D4).
  static let imagePlaceholderSize = CGSize(width: 80, height: 80)

  var body: some View {
    content
      .padding(Self.contentPadding)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
      .overlay(
        RoundedRectangle(cornerRadius: Self.cornerRadius)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
      .onHover { onHover($0) }
  }

  @ViewBuilder
  private var content: some View {
    switch item.kind {
    case .image:
      imagePreview
    case .file:
      FilePreview(item: item, maxWidth: Self.textMaxWidth)
    case .text, .richText, .link:
      TextPreview(
        text: item.previewText, maxWidth: Self.textMaxWidth, maxHeight: Self.textMaxHeight)
    }
  }

  @ViewBuilder
  private var imagePreview: some View {
    // T-OCR2: when this image has recognized text, it renders BELOW the
    // image itself — scrollable, reusing the same chunked-loading
    // `TextPreview` a plain text/link/richText preview already uses (see
    // that view's doc comment) rather than a second long-text renderer.
    VStack(alignment: .leading, spacing: 10) {
      if let blobPath = item.blobPath,
        let cached = ItemThumbnailCache.preview.image(for: blobPath)
      {
        ScaledImage(nsImage: cached, maxSide: imageMaxWidth)
      } else {
        AsyncBlobImage(item: item, blobStore: blobStore, maxSide: imageMaxWidth)
      }
      if item.hasRecognizedText, let ocrText = item.ocrText {
        Divider()
        Text("Recognized Text")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextPreview(
          text: ocrText, maxWidth: max(imageMaxWidth, Self.textMaxWidth),
          maxHeight: Self.ocrTextMaxHeight)
      }
    }
  }
}

/// Renders an `NSImage` at a DEFINITE size — its aspect ratio scaled to fit a
/// `maxSide` × `maxSide` box. A plain `.resizable().frame(maxWidth:)` image has
/// no minimum intrinsic size, so `NSHostingController.view.fittingSize` (used
/// by `ItemPreviewController` to size the popover) collapses it to near-zero
/// and the image renders tiny. Giving it a concrete width/height makes
/// `fittingSize` report the real image size, so the popover sizes to it.
///
/// Not `private`: `displaySize(for:maxSide:)` is also called directly by
/// `ItemPreviewController.boundedImageContentSize` (T-PF3 D4) so the panel
/// can be sized with the EXACT same aspect-fit math this view renders with,
/// without needing a synchronous SwiftUI layout pass to discover it — one
/// formula, two callers, rather than a second copy that could drift.
struct ScaledImage: View {
  let nsImage: NSImage
  let maxSide: CGFloat

  var body: some View {
    let size = Self.displaySize(for: nsImage.size, maxSide: maxSide)
    Image(nsImage: nsImage)
      .resizable()
      .interpolation(.medium)
      .frame(width: size.width, height: size.height)
  }

  /// Aspect-fits `source` into a `maxSide` × `maxSide` box, preserving
  /// aspect ratio. Falls back to a full `maxSide` × `maxSide` square if
  /// `source` has no usable dimensions yet (e.g. a placeholder image).
  static func displaySize(for source: CGSize, maxSide: CGFloat) -> CGSize {
    guard source.width > 0, source.height > 0 else {
      return CGSize(width: maxSide, height: maxSide)
    }
    let scale = min(maxSide / source.width, maxSide / source.height)
    return CGSize(width: source.width * scale, height: source.height * scale)
  }
}

/// Plain-text preview that loads incrementally. SwiftUI `Text` lays out its
/// whole string synchronously on the main thread (it isn't virtualized), so an
/// unbounded clip would hitch when the popover appears. This renders the first
/// `chunk` characters immediately, then appends the next `chunk` each time the
/// pointer scrolls to the bottom — a `LazyVStack` sentinel drives the load,
/// mirroring the picker list's own infinite scroll. New popovers get a fresh
/// `ItemPreview` (via `.id(item.id)`), so `visibleCount` resets per item.
private struct TextPreview: View {
  let text: String
  let maxWidth: CGFloat
  let maxHeight: CGFloat
  @State private var visibleCount: Int
  @State private var isLoadingMore = false

  /// Characters rendered initially and added each time the loader at the
  /// bottom scrolls into view. Small enough that each layout step is
  /// imperceptible.
  private static let chunk = 2_000
  /// A brief, deliberate pause before appending the next chunk. The append
  /// itself is instant, so without this the spinner would flash for a single
  /// frame and never actually be seen; this keeps it on screen long enough to
  /// read as "loading".
  private static let loadDelay = Duration.milliseconds(400)

  init(text: String, maxWidth: CGFloat, maxHeight: CGFloat) {
    self.text = text
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    _visibleCount = State(initialValue: min(Self.chunk, text.count))
  }

  private var hasMore: Bool { visibleCount < text.count }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        Text(String(text.prefix(visibleCount)))
          .font(.body)
          .textSelection(.disabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if hasMore {
          // A visible spinner below the text. In a `LazyVStack` it renders only
          // when scrolled into view; reaching it triggers `loadMore()`, which
          // shows the spinner for `loadDelay` before appending the next chunk
          // so it's actually seen (the append is otherwise instant). It then
          // re-appears at the new bottom for the next scroll.
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .onAppear { loadMore() }
        }
      }
    }
    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
  }

  /// Shows the spinner for `loadDelay`, then appends the next chunk. The guard
  /// prevents overlapping loads if the spinner briefly re-appears mid-load.
  private func loadMore() {
    guard hasMore, !isLoadingMore else { return }
    isLoadingMore = true
    Task {
      try? await Task.sleep(for: Self.loadDelay)
      visibleCount = min(visibleCount + Self.chunk, text.count)
      isLoadingMore = false
    }
  }
}

/// Filename + path (pure string ops, no disk access) plus the file's size,
/// read OFF the main thread (`Task.detached`) so it never blocks the UI — the
/// size line simply doesn't appear if the file can't be stat'd (e.g. a still-
/// materializing iCloud file). Capture no longer reads the size at all (see
/// `PasteboardReader.readFile` — that main-thread `stat` was the freeze), so
/// it's fetched here on demand.
private struct FilePreview: View {
  let item: ClipItem
  let maxWidth: CGFloat
  @State private var sizeText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(item.previewText)
        .font(.headline)
        .lineLimit(2)
      if let sizeText {
        Text(sizeText)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let path = filePath {
        Text(path)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .truncationMode(.middle)
          .textSelection(.disabled)
      }
    }
    .frame(maxWidth: maxWidth, alignment: .leading)
    .task(id: item.fileReference) {
      sizeText = nil
      guard let reference = item.fileReference, let url = URL(string: reference), url.isFileURL
      else { return }
      let bytes = await Task.detached(priority: .utility) { () -> Int? in
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
      }.value
      guard !Task.isCancelled, let bytes else { return }
      sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
  }

  /// The file's on-disk path (abbreviated with `~`), from the captured
  /// `fileReference` URL string — pure string manipulation, no disk access.
  private var filePath: String? {
    guard let reference = item.fileReference, let url = URL(string: reference), url.isFileURL
    else { return nil }
    return (url.path as NSString).abbreviatingWithTildeInPath
  }
}

/// Loads image bytes off the main thread for the preview, showing a spinner
/// while loading and a fallback icon on failure.
///
/// T-PF3 (P0 image-hang fix), D1 + D3: this used to call `NSImage(data:)`,
/// which DEFERS pixel decode to draw time — so drawing this in `ScaledImage`
/// (below) forced a full-resolution decode on the main/render thread, same
/// bug as `ItemRow`'s row thumbnail (see that file's doc comment). Now
/// decodes through `ImageThumbnailDecoder` at
/// `ItemPreview.previewImageMaxPixelSize`, entirely inside this `.task`, off
/// the main thread — and stores into `ItemThumbnailCache.preview` (its own
/// cache/budget, separate from `ItemRow`'s row-thumbnail cache — see
/// `ItemThumbnailCache.swift`'s doc comment for why sharing one cache
/// between very differently-sized images was itself a bug, D3).
private struct AsyncBlobImage: View {
  let item: ClipItem
  let blobStore: BlobStore
  let maxSide: CGFloat
  @State private var image: NSImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        ScaledImage(nsImage: image, maxSide: maxSide)
      } else if failed {
        Image(systemName: "photo")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
      } else {
        ProgressView()
          .frame(
            width: ItemPreview.imagePlaceholderSize.width,
            height: ItemPreview.imagePlaceholderSize.height)
      }
    }
    .task(id: item.blobPath) {
      failed = false
      guard let blobPath = item.blobPath else {
        failed = true
        return
      }
      let loaded = await Task.detached(priority: .utility) { () -> DecodedThumbnail? in
        guard let data = try? blobStore.read(blobPath: blobPath) else { return nil }
        return ImageThumbnailDecoder.decode(
          data, maxPixelSize: ItemPreview.previewImageMaxPixelSize)
      }.value
      guard !Task.isCancelled else { return }
      guard let loaded else {
        failed = true
        return
      }
      ItemThumbnailCache.preview.store(loaded.image, cost: loaded.byteCost, for: blobPath)
      image = loaded.image
    }
  }
}
