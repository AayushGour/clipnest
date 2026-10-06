import Foundation
import Testing

@testable import ClipnestCore

/// Unit tests for `StoreFileRecovery` — the pure, `SwiftData`-free half of
/// corrupt-store recovery extracted out of `ModelContainerRecovery.swift`
/// (P1-T4: platform-neutral extraction for Linux port reuse).
/// `SwiftDataClipStoreTests`/`SwiftDataSnippetStoreTests` already exercise
/// the end-to-end recovery behavior through `ModelContainerRecovery`'s own
/// forwarder against a real `ModelContainer`; these tests pin
/// `StoreFileRecovery`'s own contract directly, against a plain, non-
/// SwiftData `Store` type, since it is now independently reusable.
@Suite("StoreFileRecovery")
struct StoreFileRecoveryTests {

  private struct FakeStore: Equatable {
    let id: Int
  }

  private enum FakeStoreError: Error, Equatable {
    case corrupt
  }

  // MARK: - backupSuffixPrefix / makeBackupSuffix

  @Test("backupSuffixPrefix is the expected fixed literal")
  func backupSuffixPrefixIsExpectedLiteral() {
    #expect(StoreFileRecovery.backupSuffixPrefix == ".corrupt-")
  }

  @Test("makeBackupSuffix starts with backupSuffixPrefix followed by a millisecond-epoch integer")
  func makeBackupSuffixHasExpectedShape() {
    let suffix = StoreFileRecovery.makeBackupSuffix()
    #expect(suffix.hasPrefix(StoreFileRecovery.backupSuffixPrefix))
    let epochPart = suffix.dropFirst(StoreFileRecovery.backupSuffixPrefix.count)
    #expect(!epochPart.isEmpty)
    #expect(Int(epochPart) != nil)
  }

  // MARK: - sidecarURLs

  @Test("sidecarURLs returns the -wal and -shm siblings of storeURL, in that order")
  func sidecarURLsReturnsWalAndShmSiblings() {
    let storeURL = URL(fileURLWithPath: "/tmp/SomeStore.store")
    let sidecars = StoreFileRecovery.sidecarURLs(for: storeURL)
    #expect(sidecars.map(\.path) == ["/tmp/SomeStore.store-wal", "/tmp/SomeStore.store-shm"])
  }

  // MARK: - moveAside

  @Test("moveAside renames an existing file to <name><suffix> and returns true")
  func moveAsideMovesExistingFileAndReturnsTrue() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoreFileRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("Example.store")
    let contents = Data("original bytes".utf8)
    try contents.write(to: fileURL)

    let suffix = ".corrupt-1234"
    let moved = StoreFileRecovery.moveAside(fileURL, suffix: suffix, fileManager: .default)

    #expect(moved)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    let backupURL = URL(fileURLWithPath: fileURL.path + suffix)
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    #expect(try Data(contentsOf: backupURL) == contents)
  }

  @Test("moveAside returns false and creates nothing when the file does not exist")
  func moveAsideReturnsFalseWhenFileDoesNotExist() {
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoreFileRecoveryTests-missing-\(UUID().uuidString).store")

    let moved = StoreFileRecovery.moveAside(
      missingURL, suffix: ".corrupt-1234", fileManager: .default)

    #expect(!moved)
    #expect(!FileManager.default.fileExists(atPath: missingURL.path + ".corrupt-1234"))
  }

  // MARK: - openWithRecovery

  @Test(
    "openWithRecovery returns makeStore()'s result directly on first success, without logging or touching the filesystem"
  )
  func openWithRecoverySucceedsOnFirstAttempt() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoreFileRecoveryTests-success-\(UUID().uuidString).store")
    var loggedMessages: [String] = []
    var makeStoreCallCount = 0

    let result = try StoreFileRecovery.openWithRecovery(
      storeURL: storeURL,
      fileManager: .default,
      log: { loggedMessages.append($0) },
      makeStore: {
        makeStoreCallCount += 1
        return FakeStore(id: 1)
      }
    )

    #expect(result == FakeStore(id: 1))
    #expect(makeStoreCallCount == 1)
    #expect(loggedMessages.isEmpty)
  }

  @Test(
    "openWithRecovery backs up an existing store file, logs a backup message naming it, then succeeds on the second makeStore() call"
  )
  func openWithRecoveryBacksUpExistingFileAndRetries() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoreFileRecoveryTests-recover-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Example.store")
    let originalBytes = Data("not a valid store".utf8)
    try originalBytes.write(to: storeURL)

    var loggedMessages: [String] = []
    var makeStoreCallCount = 0

    let result = try StoreFileRecovery.openWithRecovery(
      storeURL: storeURL,
      fileManager: .default,
      log: { loggedMessages.append($0) },
      makeStore: {
        makeStoreCallCount += 1
        if makeStoreCallCount == 1 {
          throw FakeStoreError.corrupt
        }
        return FakeStore(id: 2)
      }
    )

    #expect(result == FakeStore(id: 2))
    #expect(makeStoreCallCount == 2)
    #expect(loggedMessages.count == 1)
    #expect(loggedMessages[0].contains("Example.store"))
    #expect(loggedMessages[0].contains(StoreFileRecovery.backupSuffixPrefix))

    // The original file was moved aside, not deleted.
    #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    let directoryContents = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    let backupURL = try #require(
      directoryContents.first {
        $0.lastPathComponent.hasPrefix("Example.store" + StoreFileRecovery.backupSuffixPrefix)
      })
    #expect(try Data(contentsOf: backupURL) == originalBytes)
  }

  @Test(
    "openWithRecovery logs the no-existing-file message when storeURL doesn't exist yet, and still retries"
  )
  func openWithRecoveryLogsNoFileMessageWhenNothingToBackUp() throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoreFileRecoveryTests-nofile-\(UUID().uuidString).store")
    var loggedMessages: [String] = []
    var makeStoreCallCount = 0

    let result = try StoreFileRecovery.openWithRecovery(
      storeURL: storeURL,
      fileManager: .default,
      log: { loggedMessages.append($0) },
      makeStore: {
        makeStoreCallCount += 1
        if makeStoreCallCount == 1 {
          throw FakeStoreError.corrupt
        }
        return FakeStore(id: 3)
      }
    )

    #expect(result == FakeStore(id: 3))
    #expect(makeStoreCallCount == 2)
    #expect(loggedMessages.count == 1)
    #expect(loggedMessages[0].contains("no existing store file was found"))
  }

  @Test(
    "openWithRecovery propagates the second makeStore() failure when recovery itself cannot succeed"
  )
  func openWithRecoveryPropagatesSecondFailure() {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoreFileRecoveryTests-unrecoverable-\(UUID().uuidString).store")
    var makeStoreCallCount = 0

    #expect(throws: FakeStoreError.corrupt) {
      let _: FakeStore = try StoreFileRecovery.openWithRecovery(
        storeURL: storeURL,
        fileManager: .default,
        log: { _ in },
        makeStore: { () throws -> FakeStore in
          makeStoreCallCount += 1
          throw FakeStoreError.corrupt
        }
      )
    }
    #expect(makeStoreCallCount == 2)
  }
}
