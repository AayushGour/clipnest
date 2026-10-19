// StoreOpenFailureRecoveryTests.swift — T-STOREALERT1.

import Foundation
import Testing

@testable import ClipnestCore
@testable import ClipnestViewModels

@Suite("StoreOpenFailureRecovery")
struct StoreOpenFailureRecoveryTests {
  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipnest-sofr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test("moves stores and sidecars into a timestamped folder, never deleting")
  func movesAside() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let names = ["ClipItems.store", "ClipItems.store-wal", "ClipItems.store-shm", "Snippets.store"]
    for n in names { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
    try Data("b".utf8).write(to: dir.appendingPathComponent("other.txt"))

    let backup = try #require(
      try StoreOpenFailureRecovery.moveStoresAside(
        in: dir, now: Date(timeIntervalSince1970: 1)))

    #expect(backup.lastPathComponent == "Reset-Backup-1000")
    for n in names {
      #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path))
      #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent(n).path))
    }
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.txt").path))
  }

  @Test("returns nil and creates nothing when no store files exist")
  func nothingToMove() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try StoreOpenFailureRecovery.moveStoresAside(in: dir) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
  }

  #if os(macOS)
    @Test("store file names are the real stores' constants")
    func fileNames() {
      #expect(StoreOpenFailureRecovery.clipStoreFileName == SwiftDataClipStore.storeFileName)
      #expect(
        StoreOpenFailureRecovery.snippetStoreFileName == SwiftDataSnippetStore.storeFileName)
    }
  #endif

  @Test("backup folder is created owner-only (0700)")
  func backupFolderPrivate() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("ClipItems.store"))
    let backup = try #require(try StoreOpenFailureRecovery.moveStoresAside(in: dir))
    let mode =
      try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == PrivateDataPermissions.directoryMode)
  }

  @Test("partial move failure reports the backup folder and mentions it in the alert")
  func partialFailure() throws {
    let dir = try makeDir()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    try Data("x".utf8).write(to: dir.appendingPathComponent("ClipItems.store"))
    // A directory squatting on the snippet store's destination makes the
    // second move fail after the first succeeded.
    let squatter = dir.appendingPathComponent("Snippets.store")
    try Data("y".utf8).write(to: squatter)
    let now = Date(timeIntervalSince1970: 2)
    let backup = dir.appendingPathComponent("Reset-Backup-2000")
    try FileManager.default.createDirectory(
      at: backup.appendingPathComponent("Snippets.store"), withIntermediateDirectories: true)
    try Data("z".utf8).write(
      to: backup.appendingPathComponent("Snippets.store").appendingPathComponent("f"))

    do {
      try StoreOpenFailureRecovery.moveStoresAside(in: dir, now: now)
      Issue.record("expected PartialMoveError")
    } catch let error as StoreOpenFailureRecovery.PartialMoveError {
      #expect(error.backupFolder.lastPathComponent == "Reset-Backup-2000")
      let moved = backup.appendingPathComponent("ClipItems.store")
      #expect(FileManager.default.fileExists(atPath: moved.path))
      let folder = StoreOpenFailureRecovery.backupFolder(from: error, known: nil)
      #expect(folder == error.backupFolder)
      let msg = StoreOpenFailureRecovery.finalFailureMessage(
        errorSummary: StoreOpenFailureRecovery.summary(for: error), backupFolder: folder)
      #expect(msg.contains("Reset-Backup-2000"))
    }
  }

  @Test("summary is metadata only; copy mentions both stores and no deletion")
  func copy() {
    let error = NSError(domain: "NSCocoaErrorDomain", code: 134110)
    let s = StoreOpenFailureRecovery.summary(for: error)
    #expect(s.contains("NSCocoaErrorDomain") && s.contains("134110"))
    let msg = StoreOpenFailureRecovery.alertMessage(errorSummary: s)
    #expect(msg.contains("snippets") && msg.contains("nothing is deleted"))
    #expect(StoreOpenFailureRecovery.confirmMessage().contains("snippets"))
  }
}
