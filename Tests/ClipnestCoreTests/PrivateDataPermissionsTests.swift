import Foundation
import Testing

@testable import ClipnestCore

@Suite("PrivateDataPermissions")
struct PrivateDataPermissionsTests {

  private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrivateDataPermissionsTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }

  private func makeFile(_ name: String, in directory: URL, mode: Int) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
  }

  @Test("A new directory is created owner-only (0700), including intermediates' target")
  func newDirectoryIsOwnerOnly() throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Clipnest", isDirectory: true)

    try PrivateDataPermissions.secureDirectory(target)

    #expect(try mode(of: target) == PrivateDataPermissions.directoryMode)
  }

  @Test("A pre-existing 0755 directory and its 0644 files are tightened to 0700 / 0600")
  func existingInstallIsTightened() throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    let store = try makeFile("ClipItems.store", in: directory, mode: 0o644)
    let wal = try makeFile("ClipItems.store-wal", in: directory, mode: 0o644)
    let shm = try makeFile("ClipItems.store-shm", in: directory, mode: 0o664)
    let blobs = directory.appendingPathComponent("blobs", isDirectory: true)
    try FileManager.default.createDirectory(
      at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

    try PrivateDataPermissions.secureDirectory(directory)
    PrivateDataPermissions.tightenContents(of: directory)

    #expect(try mode(of: directory) == PrivateDataPermissions.directoryMode)
    #expect(try mode(of: store) == PrivateDataPermissions.fileMode)
    #expect(try mode(of: wal) == PrivateDataPermissions.fileMode)
    #expect(try mode(of: shm) == PrivateDataPermissions.fileMode)
    #expect(try mode(of: blobs) == PrivateDataPermissions.directoryMode)
  }

  @Test("Tighten-only: an already stricter file is left alone")
  func neverLoosens() throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try PrivateDataPermissions.secureDirectory(directory)
    let readOnly = try makeFile("ro.store", in: directory, mode: 0o400)

    PrivateDataPermissions.tightenContents(of: directory)

    #expect(try mode(of: readOnly) == 0o400)
  }

  @Test("Missing directory or files are tolerated")
  func missingPathsAreTolerated() throws {
    let missing = makeTempDirectory()
    PrivateDataPermissions.tightenContents(of: missing)  // must not crash or create it
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    let empty = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: empty) }
    try PrivateDataPermissions.secureDirectory(empty)
    PrivateDataPermissions.tightenContents(of: empty)
    #expect(try mode(of: empty) == PrivateDataPermissions.directoryMode)
  }

  @Test("BlobStore.write tightens a pre-existing 0755 base and blobs directory")
  func blobStoreTightensExistingDirectories() throws {
    let base = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let blobs = base.appendingPathComponent(BlobStore.blobsDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)

    _ = try BlobStore(baseDirectory: base).write(Data("secret".utf8))

    #expect(try mode(of: base) == PrivateDataPermissions.directoryMode)
    #expect(try mode(of: blobs) == PrivateDataPermissions.directoryMode)
  }
}
