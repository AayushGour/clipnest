import Foundation
import Testing

@testable import ClipnestCore

/// T-SEC2 (P2, privacy): pins the expected POSIX permissions on the macOS
/// blob directory (`~/Library/Application Support/Clipnest/blobs/`), which
/// holds raw clipboard payloads (images, rich text) and is currently created
/// 0755 — umask-derived, readable by every other local account on a
/// multi-user Mac — because `BlobStore.write(_:)`'s macOS branch calls
/// `createDirectory(at:withIntermediateDirectories:)` with no explicit
/// `attributes:`, unlike the non-Apple branch two lines below it (already
/// 0700, see `blobDirectoryPosixPermissions`).
///
/// **RED today, by design.** `BlobStore.swift` lives under
/// `Sources/ClipnestCore/Store/**`, which is outside this task's file
/// ownership for this session (owned by a parallel agent) — this file pins
/// the exact behavior the fix must satisfy, as a spec for whoever lands the
/// production change, without this task editing that file itself. See the
/// senior-dev handoff for the recommended patch and the chmod-existing-
/// installs decision (T-SEC2 asked explicitly whether to chmod pre-existing
/// 0755 directories, not just gate fresh ones): YES — tightening
/// permissions is a same-owner, non-destructive metadata change (no file
/// content moves), so `write(_:)` should unconditionally reassert 0700 on
/// the directory it's about to use, whether that directory is being created
/// for the first time or already existed from a pre-fix install. A fix that
/// only gates `createDirectory`'s one-time creation call leaves every
/// existing user's already-0755 directory exposed forever, since
/// `createDirectory` is a documented no-op (attributes included) when the
/// directory already exists.
@Suite("BlobStore macOS directory permissions (T-SEC2)")
struct BlobStoreDirectoryPermissionsTests {

  private func makeTempBaseDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "BlobStoreDirectoryPermissionsTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let mode = attributes[.posixPermissions] as? NSNumber else {
      Issue.record("Expected .posixPermissions to be present for \(url.path)")
      return -1
    }
    return mode.intValue
  }

  #if os(macOS)
    @Test(
      "A freshly created blobs directory is 0700, not the umask-derived default (currently 0755)")
    func freshBlobsDirectoryIsCreatedPrivate() throws {
      let baseDirectory = makeTempBaseDirectory()
      defer { try? FileManager.default.removeItem(at: baseDirectory) }
      let store = BlobStore(baseDirectory: baseDirectory)

      _ = try store.write(Data("fresh install".utf8))

      let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
      #expect(try posixPermissions(of: blobsDirectory) == 0o700)
    }

    @Test(
      """
      An EXISTING blobs directory that is already 0755 (a pre-fix install) is tightened to \
      0700 the next time write(_:) runs — a fix that only gates fresh creation leaves every \
      current user's already-0755 directory exposed forever.
      """
    )
    func existingLooseDirectoryIsTightenedOnNextWrite() throws {
      let baseDirectory = makeTempBaseDirectory()
      defer { try? FileManager.default.removeItem(at: baseDirectory) }
      let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
      try FileManager.default.createDirectory(
        at: blobsDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      #expect(try posixPermissions(of: blobsDirectory) == 0o755)  // simulated pre-fix state

      let store = BlobStore(baseDirectory: baseDirectory)
      _ = try store.write(Data("existing install".utf8))

      #expect(try posixPermissions(of: blobsDirectory) == 0o700)
    }
  #endif
}
