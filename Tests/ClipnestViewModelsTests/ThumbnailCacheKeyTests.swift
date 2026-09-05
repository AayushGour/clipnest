// ThumbnailCacheKeyTests.swift
//
// P5 (Phase 3, Linux port): new coverage for `ClipItem.thumbnailCacheKey`
// (`ThumbnailCacheKey.swift`) — the one genuinely shared part of
// `ClipnestApp`'s `ItemThumbnailCache`, extracted for reuse by a future
// Linux thumbnail cache. Uses `makeClipItem(...)`
// (`TestSupport/ClipItemFixtures.swift`), the same fixture builder
// `PickerViewModelTests` already shares.

import ClipnestCore
import Testing

@testable import ClipnestViewModels

@Suite("ClipItem.thumbnailCacheKey")
struct ThumbnailCacheKeyTests {

  @Test("An .image item's key is its blobPath")
  func imageKeyIsBlobPath() {
    let item = makeClipItem(kind: .image, blobPath: "ab/cdef.bin")
    #expect(item.thumbnailCacheKey == "ab/cdef.bin")
  }

  @Test("A .richText item's key is its blobPath")
  func richTextKeyIsBlobPath() {
    let item = makeClipItem(kind: .richText, blobPath: "12/3456.rtf")
    #expect(item.thumbnailCacheKey == "12/3456.rtf")
  }

  @Test("A .file item's key is its fileReference")
  func fileKeyIsFileReference() {
    let item = makeClipItem(kind: .file, fileReference: "file:///Users/x/report.pdf")
    #expect(item.thumbnailCacheKey == "file:///Users/x/report.pdf")
  }

  @Test("A .text item with neither blobPath nor fileReference has no cache key")
  func textItemHasNoCacheKey() {
    let item = makeClipItem(kind: .text)
    #expect(item.thumbnailCacheKey == nil)
  }

  @Test("A .link item with neither blobPath nor fileReference has no cache key")
  func linkItemHasNoCacheKey() {
    let item = makeClipItem(kind: .link)
    #expect(item.thumbnailCacheKey == nil)
  }

  @Test("blobPath wins over fileReference when both happen to be set")
  func blobPathTakesPrecedenceOverFileReference() {
    let item = makeClipItem(kind: .image, blobPath: "ab/cdef.bin", fileReference: "file:///x")
    #expect(item.thumbnailCacheKey == "ab/cdef.bin")
  }
}
