import Foundation

// swift-crypto's `Crypto` module is API-identical for `SHA256` — this file's
// only use — so no call site below needs to change for the Linux port.
// `Package.swift` doesn't depend on `swift-crypto` yet (a separate task owns
// the manifest); this import is ready for it the moment that dependency
// lands. `swift-format`'s `OrderedImports` rule requires unconditional
// imports (`Foundation` above) ahead of any `#if`-guarded import block —
// verified against this exact file with `swift format lint --strict`.
#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

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

  /// POSIX mode (owner read/write/execute only) applied to the blob
  /// directory — and any intermediate directories `write(_:)` has to create
  /// along the way — on non-Apple platforms. Clipboard contents are
  /// inherently sensitive (coding-standards.md's Privacy/security musts);
  /// on a shared multi-user Linux box the plain `createDirectory` default
  /// (driven by the process umask — verified empirically as 0755 on macOS
  /// today under the standard 022 umask, an existing gap this task
  /// deliberately does NOT change on macOS; worth its own follow-up
  /// decision) would let every other local user list blob filenames
  /// (content hashes) and read blob bytes. macOS's `write(_:)` branch below
  /// never references this constant.
  private static let nonAppleBlobDirectoryPosixPermissions = 0o700

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

  /// XDG Base Directory Specification env var name: on non-Apple platforms,
  /// names the per-user "data files" root — the Linux analogue of macOS's
  /// `~/Library/Application Support` — that `defaultBaseDirectory`'s
  /// non-macOS branch resolves against. Read only by
  /// `xdgDataHomeDirectory(fileManager:environment:)` below, per
  /// coding-standards.md's "config in one place" rule. Not `public`: unlike
  /// `testDataRootEnvironmentVariableName`, nothing outside this file needs
  /// to reference it — it's exposed at `internal` visibility purely so
  /// `BlobStoreTests` (via `@testable import`) can build environment
  /// dictionaries against the same constant instead of a duplicated literal.
  static let xdgDataHomeEnvironmentVariableName = "XDG_DATA_HOME"

  /// The XDG spec's fallback data directory, relative to `$HOME`, used
  /// whenever `XDG_DATA_HOME` is unset or empty.
  static let xdgDataHomeFallbackRelativePath = ".local/share"

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

  /// Resolves the XDG Base Directory Specification's per-user data-files
  /// root (`$XDG_DATA_HOME`, falling back to `~/.local/share`) —
  /// `defaultBaseDirectory`'s non-macOS branch appends `appDirectoryName` to
  /// whatever this returns, the same way the macOS branch appends it to
  /// `.applicationSupportDirectory`.
  ///
  /// Deliberately a plain, platform-agnostic function — not `#if
  /// os(macOS)`/`#else`-gated — even though only `defaultBaseDirectory`'s
  /// non-macOS branch calls it in production, so it stays directly
  /// unit-testable from `swift test` running on macOS (there is no Linux
  /// toolchain in this repo's test loop yet) via the injectable
  /// `fileManager`/`environment` parameters, the same pattern this file
  /// already uses for `testDataRootEnvironmentVariableName` — no real
  /// filesystem or real process-environment mutation required to exercise
  /// the "set" / "unset" / "empty" `XDG_DATA_HOME` states.
  ///
  /// Decision: corelibs-foundation's own `FileManager.urls(for:
  /// .applicationSupportDirectory, in:)` was verified empirically (Docker
  /// `swift:6.0-jammy`, both with and without `XDG_DATA_HOME` set) to
  /// already implement exactly this resolution on Linux today. This
  /// function does not delegate to it anyway: (1) that behavior is
  /// corelibs-foundation's internal implementation choice, not a documented
  /// cross-platform contract the way `.applicationSupportDirectory` is on
  /// Darwin, and could change across toolchain versions without notice;
  /// (2) `FileManager.urls(for:in:)` takes no injectable environment, so it
  /// cannot be exercised for all three `XDG_DATA_HOME` states without
  /// mutating the real process environment, which this project's testing
  /// rules (coding-standards.md) discourage in favor of deterministic,
  /// side-effect-free tests. Spelling the two-line spec out ourselves keeps
  /// the behavior in our own hands and independently testable.
  static func xdgDataHomeDirectory(
    fileManager: FileManager,
    environment: [String: String]
  ) -> URL {
    if let override = environment[xdgDataHomeEnvironmentVariableName], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
      xdgDataHomeFallbackRelativePath, isDirectory: true)
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
  ///
  /// Linux port: the macOS branch below is byte-identical to what it was
  /// before this task — unchanged behavior, unchanged tests. The `#else`
  /// branch is new: it follows the XDG Base Directory Specification via
  /// `xdgDataHomeDirectory(fileManager:environment:)` above instead of
  /// assuming a macOS-shaped `Library/Application Support` FHS layout that
  /// doesn't exist on Linux.
  public static func defaultBaseDirectory(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    #if DEBUG
      if let override = environment[testDataRootEnvironmentVariableName], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
      }
    #endif
    #if os(macOS)
      let appSupport =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Application Support")
      return appSupport.appendingPathComponent(appDirectoryName, isDirectory: true)
    #else
      return xdgDataHomeDirectory(fileManager: fileManager, environment: environment)
        .appendingPathComponent(appDirectoryName, isDirectory: true)
    #endif
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
  ///
  /// Linux port: on non-Apple platforms the directory-creation call below
  /// passes `nonAppleBlobDirectoryPosixPermissions` (0700) so the blob
  /// directory — and any intermediate directories created along with it —
  /// are never world- or group-readable. The macOS branch is unchanged:
  /// same call, same (umask-driven) default mode as before this task.
  public func write(_ data: Data) throws -> String {
    let blobPath = "\(Self.blobsDirectoryName)/\(Self.contentHash(of: data))"
    let destination = fileURL(forBlobPath: blobPath)

    guard !fileManager.fileExists(atPath: destination.path) else {
      return blobPath
    }

    do {
      #if os(macOS)
        try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
      #else
        try fileManager.createDirectory(
          at: blobsDirectory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: Self.nonAppleBlobDirectoryPosixPermissions])
      #endif
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
