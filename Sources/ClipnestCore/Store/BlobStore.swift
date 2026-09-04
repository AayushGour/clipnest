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

  /// T-PF8 (P0 safety fix): name of the environment variable that, when set
  /// to a non-empty value, overrides the directory `defaultBaseDirectory()`
  /// resolves to.
  ///
  /// EXISTS SOLELY to stop `xcodebuild test` from touching the real,
  /// production `~/Library/Application Support/Clipnest` store + blobs.
  /// `ClipnestAppTests` is a *hosted* unit-test target (`ClipnestApp/project.yml`
  /// sets `TEST_HOST` to the built `Clipnest.app`), which means `xcodebuild
  /// test` genuinely LAUNCHES the production app binary as the process under
  /// test — `AppDelegate.applicationDidFinishLaunching` runs for real,
  /// builds a real `AppEnvironment`, and (pre-fix) opened/migrated/wrote the
  /// user's live clipboard database and blobs on every single test run, with
  /// no rollback if a migration went wrong.
  ///
  /// `ClipnestApp/project.yml`'s `ClipnestApp` scheme sets this via the
  /// `test.environmentVariables` key to a throwaway directory outside
  /// `~/Library/Application Support`. For a *hosted* unit-test target there
  /// is no separate "test runner" process to worry about losing the
  /// variable across (unlike a UI-test target's runner-app-launches-AUT-as-
  /// a-child-process shape): the host app IS the one process `xcodebuild`
  /// launches to run the injected test bundle, so a `Test` action
  /// environment variable set in the scheme reaches it directly, the same
  /// way any other process inherits variables set on it at launch — verified
  /// empirically for this fix (see the T-PF8 handoff: `ClipItems.store`'s
  /// mtime before/after an `xcodebuild test` run with this override set).
  ///
  /// Read in exactly one place — `defaultBaseDirectory(fileManager:environment:)`
  /// below — per coding-standards.md's "config in one place" rule.
  /// `BlobStore.init`, `SwiftDataClipStore.makeProductionContainer()`, and
  /// `SwiftDataSnippetStore.makeProductionContainer()` all already resolve
  /// their on-disk root through that one method (see each call site), so
  /// this override reaches all three with no separate plumbing anywhere
  /// else — the fix that actually redirects blobs, not just the metadata
  /// stores.
  ///
  /// A missing/absent variable is the untouched, byte-identical production
  /// path (see `defaultBaseDirectory(fileManager:environment:)`) — the
  /// default never depends on this variable being unset in any fragile way,
  /// it simply falls through unchanged when it's not present.
  ///
  /// **T-SEC1 (P0 security fix):** the branch that actually reads this
  /// variable is compiled ONLY into Debug builds (`#if DEBUG` around it in
  /// `defaultBaseDirectory(fileManager:environment:)` below) — a notarized
  /// Release build has no such code path in the shipped binary at all, so
  /// nothing in the user's environment (an inherited shell export,
  /// `launchctl setenv`, a malicious LaunchAgent) can silently redirect
  /// where a released Clipnest reads/writes clipboard data. This is safe
  /// because every legitimate reason to read this variable — `swift test`
  /// (builds Debug by default) and `xcodebuild test`'s `Test` action (this
  /// scheme's `TestAction buildConfiguration` is explicitly `"Debug"`, see
  /// `ClipnestApp/project.yml`'s `schemes.ClipnestApp.test.config: Debug`)
  /// — only ever needs it in a Debug build; a Release build (what
  /// `scripts/build.sh`/notarization actually ships) legitimately never
  /// does. Verified empirically that SwiftPM defines the `DEBUG`
  /// compilation condition for `-c debug` and NOT for `-c release` (the
  /// T-SEC1 handoff records the throwaway probe-package output proving
  /// this, independent of any assumption about Xcode/SwiftPM defaults).
  public static let testDataRootEnvironmentVariableName = "CLIPNEST_TEST_DATA_ROOT"

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
  /// Support/Clipnest`) — or, T-PF8, whatever
  /// `testDataRootEnvironmentVariableName` is set to, when it's set to a
  /// non-empty value. Never referenced internally by `write`/`read`/
  /// `delete` — only offered as a convenience default for production callers
  /// (e.g. `ClipboardMonitor`'s and `InMemoryClipStore`'s default initializer
  /// parameters, and `SwiftDataClipStore`/`SwiftDataSnippetStore`'s
  /// `makeProductionContainer()`). Tests always construct `BlobStore` with an
  /// explicit temp directory instead of calling this (except this file's
  /// own tests for the override logic itself, and the dedicated T-PF8
  /// isolation test proving the SwiftData production containers honor it
  /// too — see `ProductionStoreIsolationTests.swift`).
  ///
  /// - Parameter environment: Injectable so this override can be tested
  ///   deterministically without mutating the real process environment (see
  ///   `BlobStoreTests`'s override tests) — defaults to the real
  ///   `ProcessInfo.processInfo.environment` for every production call site,
  ///   none of which pass this parameter explicitly.
  ///
  /// T-SEC1: the override branch below is `#if DEBUG`-gated — see
  /// `testDataRootEnvironmentVariableName`'s doc comment for why that's the
  /// correct, sufficient gate for every real caller (`swift test`,
  /// `xcodebuild test`'s Debug-configured Test action) and why a Release
  /// build must never honor it. A Release build takes the exact same
  /// fallback path as an absent/empty variable in a Debug build — this
  /// function's production behavior with no override present is unchanged
  /// in either configuration.
  public static func defaultBaseDirectory(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    #if DEBUG
      if let override = environment[testDataRootEnvironmentVariableName], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
      }
    #endif
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
  ///
  /// T-PF4: uses `.mappedIfSafe` so real blobs (captured images run ~25MB —
  /// `.claude/logs/stress-artifacts/senior-dev-after-fix-run.txt:5`) are
  /// paged in from disk on demand rather than fully copied into a heap
  /// allocation up front. `.mappedIfSafe` only maps when Foundation judges
  /// it safe to (contiguous local-disk file, page-aligned) and transparently
  /// falls back to a normal read otherwise — never less correct, just not
  /// always mapped.
  ///
  /// Lifetime note (checked against every read call site — `ItemRow.swift`,
  /// `ItemPreview.swift`, `PickerViewModel+Paste.swift`,
  /// `OCRBackfillCoordinator.swift` — none holds the returned `Data` past
  /// its own immediate, synchronous consumption; see this task's handoff
  /// for the full site-by-site reasoning): a mapped `Data`'s bytes are
  /// backed by the file on disk, not copied at read time, so a caller that
  /// stashes the `Data` and reads its bytes only AFTER the blob has been
  /// `delete(blobPath:)`-ed risks a fault. Deleting a still-open-mapped file
  /// on a local volume is ordinarily safe (the OS keeps the underlying
  /// storage alive for the life of the mapping — the same "unlink an
  /// open/mapped file" guarantee any Unix file descriptor gets), but this is
  /// still a real constraint future call sites must respect: consume mapped
  /// bytes before/without racing a delete of the same blob, don't cache the
  /// raw `Data` itself across a delete.
  public func read(blobPath: String) throws -> Data {
    let source = fileURL(forBlobPath: blobPath)
    guard fileManager.fileExists(atPath: source.path) else {
      throw BlobStoreError.notFound
    }
    do {
      return try Data(contentsOf: source, options: .mappedIfSafe)
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
