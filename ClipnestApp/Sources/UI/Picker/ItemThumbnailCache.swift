// ItemThumbnailCache.swift
//
// T? (rich per-kind row previews): a tiny in-memory cache so scrolling/
// re-rendering `ItemRow`s doesn't reload+redecode the same `.image`/`.file`
// thumbnail bytes repeatedly. Keyed by content-addressed identifiers
// (`ClipItem.blobPath` for `.image`, `fileReference` for `.file`) — a given
// key's bytes never change, so a cache hit is always correct and there's no
// invalidation logic to write.

import AppKit

/// Tiny in-memory thumbnail cache shared by every `ItemRow`, keyed by
/// `ClipItem.blobPath` (or `fileReference` for `.file` rows). Content-
/// addressed blob paths never change bytes, so a cache hit is always
/// correct — no invalidation logic needed. `NSCache` auto-evicts under
/// memory pressure, so this needs no manual capacity bookkeeping. Not
/// persisted — rebuilt fresh each app launch.
final class ItemThumbnailCache: @unchecked Sendable {
  static let shared = ItemThumbnailCache()

  private let cache = NSCache<NSString, NSImage>()

  private init() {}

  func image(for blobPath: String) -> NSImage? {
    cache.object(forKey: blobPath as NSString)
  }

  func store(_ image: NSImage, for blobPath: String) {
    cache.setObject(image, forKey: blobPath as NSString)
  }
}
