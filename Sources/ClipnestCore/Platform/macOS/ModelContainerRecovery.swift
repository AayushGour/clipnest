// ModelContainerRecovery.swift
//
// P2-C (Linux port): moved verbatim into `Platform/macOS/` and wrapped in
// `#if os(macOS)` — mirrors `SwiftDataClipStore.swift`'s identical move; see
// that file's top doc comment for the full rationale. `import os` replaced
// with the portable `ClipnestLogger` shim (`Logging.swift`) per P2-C's
// required logging conversion: `openWithRecovery`'s `logger` parameter is
// now typed `ClipnestLogger` instead of `os.Logger` (its `privacy:`
// interpolation API is Apple-only, so it can't be the portable shim's
// surface) — both call sites (`SwiftDataClipStore`/`SwiftDataSnippetStore`,
// also moved+converted by this same task) already pass their own
// `ClipnestLogger` instance, so this is not a breaking change to any caller.
#if os(macOS)
  import Foundation
  import SwiftData

  /// Corrupt-store recovery shared by `SwiftDataClipStore.makeProductionContainer()`
  /// and `SwiftDataSnippetStore.makeProductionContainer()` — architecture-review
  /// finding: before this existed, a damaged/unreadable on-disk store file made
  /// `ModelContainer(...)` throw, which `AppEnvironment.init` propagated and
  /// `AppDelegate.applicationDidFinishLaunching` turned into an unrecoverable
  /// launch crash (no way back in for the user). Losing history to a one-time
  /// reset is far better than that, so this makes container creation
  /// self-healing instead.
  ///
  /// Kept as a small, non-`public` helper (used only from within
  /// `ClipnestCore`'s Store layer, mirroring `deleteBlobs(for:using:)` in
  /// `ClipStore.swift`) rather than duplicating the retry/backup logic in both
  /// `SwiftDataClipStore` and `SwiftDataSnippetStore` — DRY per
  /// coding-standards.md. The actual `ModelContainer(...)` call stays with each
  /// store (via the `makeContainer` closure) because it references that store's
  /// own `private` `@Model` record type, which can't cross a file boundary.
  enum ModelContainerRecovery {
    /// Re-exports `StoreFileRecovery.backupSuffixPrefix` (`StoreFileRecovery.swift`)
    /// under this type's existing name — the pure move-aside/backup-naming
    /// logic now lives there (platform-neutral, no `SwiftData` dependency, so
    /// the Linux port's future SQLite-backed stores can reuse it too). Kept
    /// here, unchanged, because existing test code references
    /// `ModelContainerRecovery.backupSuffixPrefix` directly.
    static let backupSuffixPrefix = StoreFileRecovery.backupSuffixPrefix

    /// Opens a `ModelContainer` at `storeURL`, self-healing if the existing
    /// store fails to open rather than propagating the failure straight
    /// through to the caller.
    ///
    /// A one-line forwarder to `StoreFileRecovery.openWithRecovery(storeURL:fileManager:log:makeStore:)`
    /// (`StoreFileRecovery.swift`), which now owns the actual retry/backup
    /// logic — that helper is pure `FileManager` work with no `SwiftData`
    /// dependency, generic over the store type it opens. This method's own
    /// signature (`() throws -> ModelContainer`, taking the calling store's
    /// own categorized `ClipnestLogger`) is UNCHANGED in shape, so
    /// `SwiftDataClipStore`/`SwiftDataSnippetStore` and their recovery tests
    /// need no changes; the `logger` is simply adapted to `StoreFileRecovery`'s
    /// plain `(String) -> Void` `log` parameter here. `ClipnestLogger.error`
    /// always surfaces (never dropped) and is metadata-only by construction —
    /// same discipline the old `os.Logger` call here (`.public` privacy) had,
    /// since the message `StoreFileRecovery` composes is already just a
    /// backup file NAME, never store contents.
    ///
    /// - Parameters:
    ///   - storeURL: The on-disk location `makeContainer()` opens/creates.
    ///     Only used to locate the file(s) to back up; `makeContainer()` is
    ///     what actually points a `ModelConfiguration` at it.
    ///   - logger: The calling store's own `ClipnestLogger` (already
    ///     categorized by type, e.g. `"SwiftDataClipStore"`), so a recovery
    ///     log line shows up under the store that triggered it rather than a
    ///     generic category.
    ///   - fileManager: Injectable for tests; defaults to `.default`.
    ///   - makeContainer: Attempts to open/create the container at `storeURL`.
    ///     Owned by the caller because it references that store's own
    ///     `private` `@Model` record type.
    static func openWithRecovery(
      storeURL: URL,
      logger: ClipnestLogger,
      fileManager: FileManager = .default,
      makeContainer: () throws -> ModelContainer
    ) throws -> ModelContainer {
      try StoreFileRecovery.openWithRecovery(
        storeURL: storeURL,
        fileManager: fileManager,
        log: { message in
          // Metadata only, per coding-standards.md's privacy rule — the
          // message `StoreFileRecovery` composes is already just a backup
          // file NAME (never store contents) plus whether a backup was
          // actually made.
          logger.error(message)
        },
        makeStore: makeContainer
      )
    }
  }
#endif
