// ThumbnailCacheKey.swift
//
// P5 (Phase 3, Linux port): the one genuinely platform-neutral part of
// `ClipnestApp/Sources/UI/Picker/ItemThumbnailCache.swift` — what identifies
// "the same thumbnail" for a given `ClipItem`, independent of any actual
// image-decoding/caching backend (macOS's `NSCache<NSString, NSImage>`-based
// cache stays in `ClipnestApp`; a future Linux GTK thumbnail cache reuses
// this same key). `blobPath` is set for `.image`/`.richText` items,
// `fileReference` for `.file` items, and neither for `.text`/`.link` — the
// two are mutually exclusive by construction (see `ClipboardMonitor`'s
// capture path), so `blobPath ?? fileReference` always resolves to whichever
// one a given kind actually populates.
//
// `ItemRow.swift`'s existing `cacheKey` (`item.kind == .image ? item.blobPath
// : item.fileReference`) is NOT refactored to use this — out of P5's scope
// (`ItemRow.swift` isn't one of the files this task moves); a follow-up can
// dedupe it once a Linux UI actually consumes this property. Both formulas
// are equivalent given the mutual-exclusivity invariant above.
import ClipnestCore

extension ClipItem {
  /// See this file's top doc comment. `nil` for `.text`/`.link` items, which
  /// have no thumbnail at all.
  public var thumbnailCacheKey: String? {
    blobPath ?? fileReference
  }
}
