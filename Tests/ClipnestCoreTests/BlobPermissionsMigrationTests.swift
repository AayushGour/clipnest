import Foundation
import Testing

@testable import ClipnestCore

/// T-PERM2: new blobs are 0600; the one-time background pass tightens legacy
/// loose blobs and persists its marker only on a clean, complete pass.
@Suite("Blob file permissions (T-PERM2)")
struct BlobPermissionsMigrationTests {
  private let fm = FileManager.default

  private func makeBase() -> URL {
    fm.temporaryDirectory.appendingPathComponent("BlobPerm-\(UUID().uuidString)", isDirectory: true)
  }

  private func mode(_ url: URL) throws -> Int {
    (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
  }

  private func makeLegacy(_ url: URL, mode: Int, data: String = "x") throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(data.utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  private final class Marker: @unchecked Sendable {
    var done = false
    var sets = 0
  }

  @Test("A newly written blob is 0600")
  func newBlobIsPrivate() throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let store = BlobStore(baseDirectory: base)
    let path = try store.write(Data("secret".utf8))
    #expect(try mode(base.appendingPathComponent(path)) == 0o600)
    #expect(try store.read(blobPath: path) == Data("secret".utf8))
    // No temp files left behind.
    let names = try fm.contentsOfDirectory(atPath: store.blobsDirectoryURL.path)
    #expect(names == [path.replacingOccurrences(of: "blobs/", with: "")])
  }

  @Test("Pass tightens 0644 files and nested entries, leaves 0400 alone, marks done")
  func tightensLegacyTree() throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let blobs = base.appendingPathComponent("blobs", isDirectory: true)
    let loose = blobs.appendingPathComponent("a")
    let nested = blobs.appendingPathComponent("sub/b")
    let readOnly = blobs.appendingPathComponent("c")
    try makeLegacy(loose, mode: 0o644)
    try makeLegacy(nested, mode: 0o644)
    try makeLegacy(readOnly, mode: 0o400)
    try fm.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: blobs.appendingPathComponent("sub").path)
    let marker = Marker()

    let outcome = BlobPermissionsMigration.runIfNeeded(
      blobsDirectory: blobs, isDone: { marker.done }, markDone: { marker.done = true })

    #expect(outcome == .completed)
    #expect(try mode(loose) == 0o600)
    #expect(try mode(nested) == 0o600)
    #expect(try mode(blobs.appendingPathComponent("sub")) == 0o700)
    #expect(try mode(readOnly) == 0o400)
    #expect(marker.done)
  }

  @Test("With the marker set, a second launch is a no-op")
  func markerMakesSecondRunNoOp() throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let blobs = base.appendingPathComponent("blobs", isDirectory: true)
    let file = blobs.appendingPathComponent("a")
    try makeLegacy(file, mode: 0o644)
    let marker = Marker()
    marker.done = true

    let outcome = BlobPermissionsMigration.runIfNeeded(
      blobsDirectory: blobs, isDone: { marker.done }, markDone: { marker.sets += 1 })

    #expect(outcome == .alreadyDone)
    #expect(try mode(file) == 0o644)
    #expect(marker.sets == 0)
  }

  @Test("A cancelled pass does not set the marker")
  func cancelledPassLeavesMarkerUnset() throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let blobs = base.appendingPathComponent("blobs", isDirectory: true)
    try makeLegacy(blobs.appendingPathComponent("a"), mode: 0o644)
    let marker = Marker()

    let outcome = BlobPermissionsMigration.runIfNeeded(
      blobsDirectory: blobs, isDone: { marker.done }, markDone: { marker.done = true },
      isCancelled: { true })

    #expect(outcome == .cancelled)
    #expect(!marker.done)
  }

  @Test("A failure to change an entry (transient) does not set the marker")
  func failedChangeLeavesMarkerUnset() throws {
    let base = makeBase()
    defer {
      try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
      try? fm.removeItem(at: base)
    }
    let blobs = base.appendingPathComponent("blobs", isDirectory: true)
    let sub = blobs.appendingPathComponent("sub", isDirectory: true)
    try makeLegacy(sub.appendingPathComponent("a"), mode: 0o644)
    // Unreadable (0000) directory: listing it fails with a non-"missing" error.
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sub.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sub.path) }
    // Root bypasses permission checks; skip meaningfully there.
    guard geteuid() != 0 else { return }
    let marker = Marker()

    let outcome = BlobPermissionsMigration.runIfNeeded(
      blobsDirectory: blobs, isDone: { marker.done }, markDone: { marker.done = true })

    #expect(outcome == .transientFailures)
    #expect(!marker.done)
  }

  @Test("A missing blobs directory completes and marks done")
  func missingDirectoryCompletes() {
    let marker = Marker()
    let outcome = BlobPermissionsMigration.runIfNeeded(
      blobsDirectory: makeBase().appendingPathComponent("blobs"),
      isDone: { marker.done }, markDone: { marker.done = true })
    #expect(outcome == .completed)
    #expect(marker.done)
  }

  @Test("Symlinks are not followed")
  func symlinkNotFollowed() throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let blobs = base.appendingPathComponent("blobs", isDirectory: true)
    let outside = base.appendingPathComponent("outside")
    try makeLegacy(outside, mode: 0o644)
    let outsideDir = base.appendingPathComponent("outsideDir", isDirectory: true)
    let innerFile = outsideDir.appendingPathComponent("inner")
    try makeLegacy(innerFile, mode: 0o644)
    try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
    try fm.createSymbolicLink(
      at: blobs.appendingPathComponent("link"), withDestinationURL: outside)
    try fm.createSymbolicLink(
      at: blobs.appendingPathComponent("dirlink"), withDestinationURL: outsideDir)

    let marker = Marker()
    BlobPermissionsMigration.runIfNeeded(
      blobsDirectory: blobs, isDone: { marker.done }, markDone: { marker.done = true })

    #expect(try mode(outside) == 0o644)
    #expect(try mode(innerFile) == 0o644)
    #expect(marker.done)
  }

  @Test("start(...) runs in the background and sets the marker keyed by the blobs path")
  func startRunsInBackground() async throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let store = BlobStore(baseDirectory: base)
    let file = store.blobsDirectoryURL.appendingPathComponent("a")
    try makeLegacy(file, mode: 0o644)
    let marker = Marker()

    let outcome = await BlobPermissionsMigration.start(
      blobStore: store, isDone: { _ in marker.done },
      markDone: { key in
        #expect(key == BlobPermissionsMigration.markerKey(for: store.blobsDirectoryURL))
        marker.done = true
      }
    ).value

    #expect(outcome == .completed)
    #expect(try mode(file) == 0o600)
  }

  @Test("Sweep removes stale .tmp- files, keeps fresh ones and real blobs")
  func sweepStaleTemporaryFiles() throws {
    let base = makeBase()
    defer { try? fm.removeItem(at: base) }
    let store = BlobStore(baseDirectory: base)
    let blobs = store.blobsDirectoryURL
    let prefix = BlobStore.temporaryFilePrefix
    let old = blobs.appendingPathComponent("\(prefix)old")
    let fresh = blobs.appendingPathComponent("\(prefix)fresh")
    let real = blobs.appendingPathComponent("realblob")
    try makeLegacy(old, mode: 0o600)
    try makeLegacy(fresh, mode: 0o600)
    try makeLegacy(real, mode: 0o600)
    let now = Date()
    let stale = now.addingTimeInterval(-BlobPermissionsMigration.staleTemporaryFileAge - 60)
    try fm.setAttributes([.modificationDate: stale], ofItemAtPath: old.path)
    try fm.setAttributes([.modificationDate: stale], ofItemAtPath: real.path)

    let removed = BlobPermissionsMigration.sweepStaleTemporaryFiles(in: blobs, now: now)

    #expect(removed == 1)
    #expect(!fm.fileExists(atPath: old.path))
    #expect(fm.fileExists(atPath: fresh.path))
    #expect(fm.fileExists(atPath: real.path))
  }

  @Test("isMissing recognises Cocoa, POSIX and underlying POSIX ENOENT only")
  func isMissingVariants() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    let wrapped = NSError(
      domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: posix])
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
    let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    let wrappedEacces = NSError(
      domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: eacces])
    #expect(PrivateDataPermissions.isMissing(posix))
    #expect(PrivateDataPermissions.isMissing(wrapped))
    #expect(PrivateDataPermissions.isMissing(cocoa))
    #expect(!PrivateDataPermissions.isMissing(eacces))
    #expect(!PrivateDataPermissions.isMissing(wrappedEacces))
  }
}
