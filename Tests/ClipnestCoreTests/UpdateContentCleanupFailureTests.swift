import Foundation
import Testing

@testable import ClipnestCore
@testable import ClipnestSQLite

#if os(macOS)
  import SwiftData
#endif

/// `FileManager` whose `removeItem(at:)` always fails, so `BlobStore.delete`
/// throws `BlobStoreError.ioFailure` for any blob that exists.
private final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}

/// T-EDIT17: once `updateContent`'s write has committed, a failure deleting the
/// now-unreferenced old blob must not surface as an error — the edit succeeded
/// and callers (the coordinator's clipboard re-sync) must proceed.
@Suite("updateContent post-commit blob cleanup failure")
struct UpdateContentCleanupFailureTests {
  private func makeFixture() throws -> (blobStore: BlobStore, directory: URL, oldPath: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UpdateContentCleanup-\(UUID().uuidString)", isDirectory: true)
    let blobStore = BlobStore(baseDirectory: directory, fileManager: FailingRemoveFileManager())
    let oldPath = try blobStore.write(Data("{\\rtf1 old}".utf8))
    return (blobStore, directory, oldPath)
  }

  private func richItem(blobPath: String) -> ClipItem {
    ClipItem(
      createdAt: Date(), kind: .richText, previewText: "old", contentHash: "old-hash",
      byteSize: 3, blobPath: blobPath)
  }

  private let plainUpdate = ClipContentUpdate(
    derived: DerivedClipContent(
      kind: .text, previewText: "new", contentHash: "new-hash", byteSize: 3),
    blobPath: nil)

  private func assertUpdateSucceeds(_ store: any ClipStore, oldPath: String) async throws {
    let item = try await store.insertOrBumpDuplicate(richItem(blobPath: oldPath))
    let result = try await store.updateContent(item.id, with: plainUpdate)
    #expect(result.item.previewText == "new")
    #expect(try await store.fetchAll().first?.contentHash == "new-hash")
  }

  @Test func inMemoryStoreSwallowsCleanupFailure() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await assertUpdateSucceeds(InMemoryClipStore(blobStore: f.blobStore), oldPath: f.oldPath)
  }

  @Test func sqliteStoreSwallowsCleanupFailure() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let store = try SQLiteClipStore(baseDirectory: f.directory, blobStore: f.blobStore)
    try await assertUpdateSucceeds(store, oldPath: f.oldPath)
  }

  #if os(macOS)
    @Test func swiftDataStoreSwallowsCleanupFailure() async throws {
      let f = try makeFixture()
      defer { try? FileManager.default.removeItem(at: f.directory) }
      let store = SwiftDataClipStore(
        modelContainer: try SwiftDataClipStore.makeTestContainer(), blobStore: f.blobStore)
      try await assertUpdateSucceeds(store, oldPath: f.oldPath)
    }
  #endif
}

/// T-EDIT17 round 2: a failing post-commit reference check must keep the blob
/// (the committed row may reference it), never delete it.
@Suite("blobPathsKeptAfterCommit")
struct BlobPathsKeptAfterCommitTests {
  private struct Boom: Error {}

  @Test func throwingReferenceCheckTreatsPathAsReferenced() {
    let kept = blobPathsKeptAfterCommit(candidates: ["a", nil, "b"]) { _ in throw Boom() }
    #expect(kept == ["a", "b"])
  }

  @Test func successfulChecksKeepOnlyReferencedPaths() {
    let kept = blobPathsKeptAfterCommit(candidates: ["a", "b", "a"]) { $0 == "a" }
    #expect(kept == ["a"])
  }

  @Test func mixedFailureKeepsOnlyTheFailedAndReferenced() {
    let kept = blobPathsKeptAfterCommit(candidates: ["a", "b", "c"]) { path in
      if path == "b" { throw Boom() }
      return path == "a"
    }
    #expect(kept == ["a", "b"])
  }
}
