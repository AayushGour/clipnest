import Foundation
import Testing

@testable import ClipnestCore

@Suite("BlobStore")
struct BlobStoreTests {

  /// A fresh, throwaway temp directory per test — never the real
  /// `~/Library/Application Support`, per coding-standards.md's testing rules.
  private func makeTempBaseDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "BlobStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("Round-trip write then read returns identical bytes")
  func writeReadRoundTrip() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    let payload = Data("hello blob".utf8)

    let blobPath = try store.write(payload)
    let readBack = try store.read(blobPath: blobPath)

    #expect(readBack == payload)
  }

  @Test("write returns a relative blobPath rooted at 'blobs/'")
  func writeReturnsRelativePath() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    let blobPath = try store.write(Data("relative path check".utf8))

    #expect(blobPath.hasPrefix("\(BlobStore.blobsDirectoryName)/"))
  }

  @Test("Writing identical bytes twice results in exactly one file on disk")
  func identicalWritesDedupToOneFile() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    let payload = Data("same bytes, written twice".utf8)

    let firstPath = try store.write(payload)
    let secondPath = try store.write(payload)

    #expect(firstPath == secondPath)
    let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
    let contents = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
    #expect(contents.count == 1)
  }

  @Test("Writing different bytes creates two separate files")
  func differentWritesCreateSeparateFiles() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    let firstPath = try store.write(Data("content A".utf8))
    let secondPath = try store.write(Data("content B".utf8))

    #expect(firstPath != secondPath)
    let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
    let contents = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
    #expect(contents.count == 2)
  }

  @Test("delete removes the file from disk")
  func deleteRemovesFile() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    let blobPath = try store.write(Data("to be deleted".utf8))

    try store.delete(blobPath: blobPath)

    #expect(throws: BlobStoreError.notFound) {
      try store.read(blobPath: blobPath)
    }
  }

  @Test("Reading a nonexistent blob path throws .notFound")
  func readMissingThrows() {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    #expect(throws: BlobStoreError.notFound) {
      try store.read(blobPath: "\(BlobStore.blobsDirectoryName)/does-not-exist")
    }
  }

  @Test("Deleting a nonexistent blob path is a no-op, not an error (idempotent cleanup)")
  func deleteMissingIsIdempotent() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    try store.delete(blobPath: "\(BlobStore.blobsDirectoryName)/does-not-exist")
  }

  @Test("contentHash(of:) is stable for identical bytes and differs for different bytes")
  func contentHashStableAndDistinct() {
    let dataA1 = Data("payload A".utf8)
    let dataA2 = Data("payload A".utf8)
    let dataB = Data("payload B".utf8)

    #expect(BlobStore.contentHash(of: dataA1) == BlobStore.contentHash(of: dataA2))
    #expect(BlobStore.contentHash(of: dataA1) != BlobStore.contentHash(of: dataB))
  }
}
