// ItemThumbnailCacheTests.swift
//
// T-PF3 (P0 image-hang fix), D2 + D3: the old `ItemThumbnailCache` was a
// single `NSCache<NSString, NSImage>()` with no `countLimit`/
// `totalCostLimit`, and `setObject` was called with no `cost:`, so it grew
// without bound for the process's lifetime — its header comment claimed
// `NSCache` "auto-evicts under memory pressure", which is false on macOS
// (`NSImage` isn't `NSDiscardableContent`, and macOS delivers no
// iOS-style memory-warning callback to `NSCache`). This suite pins down the
// two properties that fix depends on: (1) a `SizedImageCache` configured
// with a real `totalCostLimit` actually evicts once stored cost exceeds it,
// and (2) content-addressed keying still returns a cache HIT for the same
// key across repeated reads — the mechanism `ItemRow`/`ItemPreview` rely on
// to avoid re-decoding bytes they've already decoded once.
//
// Uses freestanding `SizedImageCache` instances (not the shared
// `ItemThumbnailCache.row`/`.preview` singletons) so each test picks its own
// small limits and stays fast/deterministic without touching process-wide
// shared state other tests might also touch.

import AppKit
import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import Clipnest

@Suite("SizedImageCache")
struct SizedImageCacheTests {

  @Test("A stored entry is returned by a later read under the same key")
  func storeThenReadReturnsTheStoredImage() {
    let cache = SizedImageCache(countLimit: 10, totalCostLimit: 10 * 1_048_576)
    let image = Self.makeTinyImage()

    cache.store(image, cost: 64, for: "content-hash-abc")

    #expect(cache.image(for: "content-hash-abc") === image)
  }

  @Test("A key that was never stored misses")
  func unknownKeyMisses() {
    let cache = SizedImageCache(countLimit: 10, totalCostLimit: 10 * 1_048_576)
    #expect(cache.image(for: "never-stored") == nil)
  }

  @Test("Repeated reads of the same key return the identical cached object (no re-decode needed)")
  func keyingPreventsRedecodeAcrossRepeatedReads() {
    let cache = SizedImageCache(countLimit: 10, totalCostLimit: 10 * 1_048_576)
    let image = Self.makeTinyImage()
    cache.store(image, cost: 64, for: "content-hash-xyz")

    // A content-addressed key's bytes never change, so `ItemRow`/
    // `ItemPreview` call `image(for:)` on every re-render and expect the
    // SAME already-decoded object back, not a fresh decode. Reference
    // identity (`===`) is the direct proof that no new `NSImage` was
    // created between reads.
    let firstRead = cache.image(for: "content-hash-xyz")
    let secondRead = cache.image(for: "content-hash-xyz")

    #expect(firstRead != nil)
    #expect(firstRead === secondRead)
  }

  @Test("A cache configured with a small totalCostLimit evicts once stored cost exceeds it")
  func evictsOnceStoredCostExceedsTotalCostLimit() {
    // Each entry below costs far more (100 KB) than the cache's total
    // budget (1 KB) — `NSCache`'s `totalCostLimit` eviction isn't
    // guaranteed by Apple to be synchronous within `setObject`, but is
    // empirically so; a 100x-over-budget margin keeps this reliable rather
    // than borderline.
    let cache = SizedImageCache(countLimit: 50, totalCostLimit: 1_024)
    let image = Self.makeTinyImage()
    let costPerEntry = 100 * 1_024

    for index in 0..<20 {
      cache.store(image, cost: costPerEntry, for: "key-\(index)")
    }

    let survivingCount = (0..<20).filter { cache.image(for: "key-\($0)") != nil }.count
    #expect(survivingCount < 20)
  }

  @Test("ItemThumbnailCache exposes separate row and preview caches")
  func rowAndPreviewAreDistinctCaches() {
    // D3: row thumbnails and preview images must not share a cache/budget —
    // storing under the same key in one must not appear in the other.
    let image = Self.makeTinyImage()
    let key = "shared-blob-path-for-distinctness-test"

    ItemThumbnailCache.row.store(image, cost: 64, for: key)

    #expect(ItemThumbnailCache.row.image(for: key) === image)
    #expect(ItemThumbnailCache.preview.image(for: key) == nil)
  }

  // MARK: - Test helpers

  /// A minimal, valid `NSImage` — cache mechanics (store/read/evict) don't
  /// need real decoded pixel content, just a distinguishable object.
  private static func makeTinyImage() -> NSImage {
    NSImage(size: NSSize(width: 4, height: 4))
  }
}
