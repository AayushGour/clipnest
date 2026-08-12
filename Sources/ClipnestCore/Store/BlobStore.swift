import CryptoKit
import Foundation

/// Errors surfaced by `BlobStore`.
public enum BlobStoreError: Error, Equatable, Sendable {
  /// No blob exists at the given `blobPath`. Only thrown by `read(blobPath:)`
  /// — `delete(blobPath:)` is intentionally idempotent, see its doc comment.
  case notFound
  case ioFailure(underlying: String)
}

/// Content-addressed disk storage for large clipboard payloads (currently
/// just captured image bytes — see plan task T20) that don't belong in
/// `ClipStore`'s metadata-only records.
///
/// Writing identical bytes twice never creates a second file: the same
/// SHA256 hash always maps to the same relative path, so a second `write(_:)`
/// with the same bytes is a cheap no-op that returns the existing path.
///
/// The base directory is always injected — never hardcoded inline in any
/// read/write/delete path — so tests point it at a throwaway temp directory
/// and never touch the real `~/Library/Application Support`. Production
/// callers get a real default via `defaultBaseDirectory()`.
public struct BlobStore: Sendable {
  /// The subdirectory (under `baseDirectory`) blobs are written into. Public
  /// so callers (e.g. Settings' storage-usage display, plan task T28) can
  /// compute the same path without duplicating the literal string.
  public static let blobsDirectoryName = "blobs"

  private static let appDirectoryName = "Clipnest"

  private let baseDirectory: URL
  // `FileManager` isn't `Sendable` in this SDK's overlay even though Apple
  // documents the shared/default instance (and any instance used only for
  // non-delegate, read/write-by-path calls like the ones here) as safe for
  // concurrent use from multiple threads — `nonisolated(unsafe)` reflects
  // that documented guarantee instead of forcing `BlobStore` to give up
  // value-type `Sendable` synthesis.
  private nonisolated(unsafe) let fileManager: FileManager

  public init(baseDirectory: URL, fileManager: FileManager = .default) {
    self.baseDirectory = baseDirectory
    self.fileManager = fileManager
  }

  /// The real production base directory (`~/Library/Application
  /// Support/Clipnest`). Never referenced internally by `write`/`read`/
  /// `delete` — only offered as a convenience default for production callers
  /// (e.g. `ClipboardMonitor`'s and `InMemoryClipStore`'s default initializer
  /// parameters). Tests always construct `BlobStore` with an explicit temp
  /// directory instead of calling this.
  public static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
    let appSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support")
    return appSupport.appendingPathComponent(appDirectoryName, isDirectory: true)
  }

  /// The canonical content-hash algorithm used both for `BlobStore`'s
  /// content-addressed filenames and for `PasteboardReader`'s
  /// `ClipItem.contentHash` output — kept in exactly one place per
  /// coding-standards.md's DRY rule (this became a real, not hypothetical,
  /// duplicate the moment `PasteboardReader` needed identical SHA256-hex
  /// logic to the one `write(_:)` already had).
  public static func contentHash(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private var blobsDirectory: URL {
    baseDirectory.appendingPathComponent(Self.blobsDirectoryName, isDirectory: true)
  }

  private func fileURL(forBlobPath blobPath: String) -> URL {
    baseDirectory.appendingPathComponent(blobPath)
  }

  /// Writes `data` to a content-addressed path and returns the resulting
  /// relative `blobPath` (rooted at `"blobs/"`) to store on a `ClipItem`.
  public func write(_ data: Data) throws -> String {
    let blobPath = "\(Self.blobsDirectoryName)/\(Self.contentHash(of: data))"
    let destination = fileURL(forBlobPath: blobPath)

    guard !fileManager.fileExists(atPath: destination.path) else {
      return blobPath
    }

    do {
      try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
      try data.write(to: destination, options: .atomic)
    } catch {
      throw BlobStoreError.ioFailure(underlying: String(describing: error))
    }

    return blobPath
  }

  /// Reads the bytes at `blobPath`.
  /// - Throws: `BlobStoreError.notFound` if no blob exists at that path.
  public func read(blobPath: String) throws -> Data {
    let source = fileURL(forBlobPath: blobPath)
    guard fileManager.fileExists(atPath: source.path) else {
      throw BlobStoreError.notFound
    }
    do {
      return try Data(contentsOf: source)
    } catch {
      throw BlobStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// Deletes the blob at `blobPath`.
  ///
  /// Idempotent: if no file exists there already, this returns normally
  /// instead of throwing. Cleanup call sites (`ClipStore.delete`/
  /// `clearHistory`/`enforceRetention`) may reference a blob that's already
  /// gone — that's not a genuine failure, so `delete` behaves like `rm -f`,
  /// deliberately unlike `read`, which throws on a missing path because
  /// reading a dangling `blobPath` does indicate a real data-integrity issue
  /// the caller needs to know about.
  public func delete(blobPath: String) throws {
    let target = fileURL(forBlobPath: blobPath)
    guard fileManager.fileExists(atPath: target.path) else { return }
    do {
      try fileManager.removeItem(at: target)
    } catch {
      throw BlobStoreError.ioFailure(underlying: String(describing: error))
    }
  }
}
