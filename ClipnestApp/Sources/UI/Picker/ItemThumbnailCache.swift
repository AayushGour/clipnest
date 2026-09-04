// ItemThumbnailCache.swift
//
// T? (rich per-kind row previews): a tiny in-memory cache so scrolling/
// re-rendering `ItemRow`s doesn't reload+redecode the same `.image`/`.file`
// thumbnail bytes repeatedly. Keyed by content-addressed identifiers
// (`ClipItem.blobPath` for `.image`, `fileReference` for `.file`) — a given
// key's bytes never change, so a cache hit is always correct and there's no
// invalidation logic to write.
//
// T-PF3 (P0 image-hang fix), D2 + D3: this used to be a SINGLE
// `NSCache<NSString, NSImage>()` with no `countLimit`/`totalCostLimit`, and
// `setObject` was called without a `cost:`, so even setting a
// `totalCostLimit` would have been inert — the cache grew without bound for
// the process's lifetime, and `ItemRow`'s tiny 20pt row thumbnails shared
// the exact same cache/budget as `ItemPreview`'s full-size popover images.
// The comment that used to sit here claimed "`NSCache` auto-evicts under
// memory pressure, so this needs no manual capacity bookkeeping" — that does
// NOT hold on macOS: `NSImage` doesn't conform to `NSDiscardableContent`,
// and macOS doesn't deliver iOS-style memory-warning callbacks to
// `NSCache`, so without an explicit `countLimit`/`totalCostLimit` (and a
// real per-entry `cost:`), nothing ever evicts anything. Below are now TWO
// caches — row thumbnails and preview images decode to very different
// resolutions (see `ImageThumbnailDecoder` and each cache's own doc comment
// below) — each with both a `countLimit` and a real byte-based
// `totalCostLimit`, which is the only actual eviction mechanism on macOS.
//
// Keying is unchanged and still correct: content-addressed `blobPath`/
// `fileReference` never changes bytes, so a cache hit is always valid — no
// invalidation logic needed. Not persisted — rebuilt fresh each app launch.

import AppKit

enum ItemThumbnailCache {
  /// Row icons (`ItemRow`) decode to at most
  /// `ItemIconThumbnail.rowThumbnailMaxPixelSize` (~64px) per side — see
  /// that constant's doc comment. At the 4-bytes/pixel cost estimate
  /// (`DecodedThumbnail.byteCost`) that's ~16 KB/entry, so `countLimit`
  /// alone (a long scroll through an image-heavy history) would already
  /// cap real memory around 8 MB — `totalCostLimit` is set a bit above that
  /// as a defense-in-depth second bound, per T-PF3's requirement that each
  /// cache have BOTH limits, not just one.
  static let row = SizedImageCache(
    countLimit: 500,
    totalCostLimit: 16 * Self.bytesPerMebibyte)

  /// Preview images (`ItemPreview`) decode to at most
  /// `ItemPreview.previewImageMaxPixelSize` (~1600px) per side — far larger
  /// per entry than a row thumbnail (worst case ~9.8 MB vs. ~16 KB). Only a
  /// handful are ever live at once (the current hover, plus whatever was
  /// hovered moments ago and hasn't been evicted yet), so `countLimit` stays
  /// small; `totalCostLimit` is the binding constraint in the worst case
  /// (12 worst-case-sized entries would be ~117 MB, well over the 64 MB cap
  /// below), which is exactly the point — bytes, not just entry count,
  /// bound this cache's memory.
  static let preview = SizedImageCache(
    countLimit: 12,
    totalCostLimit: 64 * Self.bytesPerMebibyte)

  private static let bytesPerMebibyte = 1_048_576
}

/// A small `NSCache` wrapper that requires a real byte `cost:` per entry, so
/// `totalCostLimit` (unlike a bare `NSCache<NSString, NSImage>()` that never
/// passes a cost to `setObject`) actually bounds memory instead of being
/// inert. `countLimit` is a secondary cap, useful when many small entries
/// arrive faster than the cost limit alone would evict them.
///
/// `@unchecked Sendable`: `NSCache` is documented thread-safe for concurrent
/// access from multiple threads, but isn't itself `Sendable` in Swift's type
/// system — this wrapper only ever forwards to it, so it's safe to share
/// across the `Task.detached` background loaders and the main-actor views
/// that read from it.
final class SizedImageCache: @unchecked Sendable {
  private let cache = NSCache<NSString, NSImage>()

  init(countLimit: Int, totalCostLimit: Int) {
    cache.countLimit = countLimit
    cache.totalCostLimit = totalCostLimit
  }

  func image(for key: String) -> NSImage? {
    cache.object(forKey: key as NSString)
  }

  func store(_ image: NSImage, cost: Int, for key: String) {
    cache.setObject(image, forKey: key as NSString, cost: cost)
  }
}
