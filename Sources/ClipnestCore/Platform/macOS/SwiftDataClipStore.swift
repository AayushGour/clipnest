// SwiftDataClipStore.swift
//
// P2-C (Linux port): moved verbatim into `Platform/macOS/` and wrapped in
// `#if os(macOS)` — this file's `@Model`-backed `ClipItemRecord` and its
// `SwiftData`/`ModelContainer` usage are Apple-only, and stay in the
// `ClipnestCore` module (not a separate target) so the existing test suite's
// `@testable import ClipnestCore` reach into this file's `private`/internal
// symbols (`ClipItemRecord`, `insertRecordWithEmptyNormalizedTextForTesting`,
// `makeContainerForTesting`, `backfillCompleteDefaultsKeyPrefix`, etc.) keeps
// compiling unchanged. See `Platform/PlatformDefaults.swift`'s doc comment
// for the overall shape of this split. No logic changed by this move — only
// the `#if os(macOS)` wrapper, `import os` → `ClipnestLogger` (P2-C's
// required logging conversion; `os.Logger`'s `privacy:` interpolation is
// Apple-only, so it can't be the portable shim's API — see `Logging.swift`),
// and a `PlatformDefaults.imagePixelHasher` bridge (see the `#if os(macOS)`
// extension near the bottom of this file's sibling, `CoreGraphicsImagePixelHasher.swift`).
#if os(macOS)
  import Foundation
  import SwiftData

  /// The off-actor blob-read-plus-hash outcome `migrateOneImageContentHash(_:)`
  /// classifies its `Task.detached` work into, before hopping back onto the
  /// `SwiftDataClipStore` actor to persist it. File-private and `Sendable` —
  /// crosses the `Task.detached` boundary but never leaves this file.
  private enum ImageBlobHashResult: Sendable {
    case hash(String)
    case missingOrUndecodable
    case transientReadFailure
  }

  /// SwiftData-backed `ClipStore` — the production persistence layer (plan
  /// task T40, project-context.md decision D6).
  ///
  /// Per D6, the domain `ClipItem` struct never crosses this store's boundary
  /// as a SwiftData type: internally, `SwiftDataClipStore` owns a *private*
  /// `@Model` entity (`ClipItemRecord`, defined below) and maps to/from
  /// `ClipItem` on every call. Callers only ever see `ClipItem`.
  ///
  /// Implemented as a plain `actor` (rather than the `@ModelActor` macro) so
  /// the initializer can also inject the shared `BlobStore` instance the
  /// composition root requires (see `AppEnvironment`'s doc comment on why
  /// `ClipStore` and `ClipboardMonitor` must share one `BlobStore`) — the
  /// `@ModelActor` macro synthesizes a fixed `init(modelContainer:)` with no
  /// room for that second dependency. `ModelContainer` is `Sendable`, so it
  /// crosses into the actor's `init` cleanly; the actor's own isolation then
  /// guarantees every `ModelContext`/`ClipItemRecord` access is serialized,
  /// which is all `@ModelActor` would have bought us here.
  public actor SwiftDataClipStore: ClipStore {
    private let modelContext: ModelContext
    private let blobStore: BlobStore
    private let imagePixelHasher: any ImagePixelHashing
    /// T-PF5c (restructure): where the image-contentHash backfill's one-shot
    /// "never scan again" marker is persisted — see
    /// `scheduleImageContentHashBackfillIfNeeded()`'s doc comment. Reuses the
    /// SAME `OneShotMigrationStorage` protocol `OneShotStoreMigration.swift`
    /// already defines (never redefined here — coding-standards.md's DRY
    /// rule), but is plumbed independently of that helper's own `run(...)`,
    /// which this migration deliberately no longer calls — see this
    /// property's user for why. Defaulted to `UserDefaults.standard`,
    /// matching every other production marker in this file; tests inject a
    /// fake (mirrors `OneShotStoreMigrationTests.FakeOneShotMigrationStorage`'s
    /// own rationale for not exercising real `UserDefaults` I/O in a test).
    private let migrationStorage: OneShotMigrationStorage
    /// T-PF5c (restructure): the in-flight (or just-finished) background
    /// image-contentHash backfill pass started by `prepare()`, if any — see
    /// `scheduleImageContentHashBackfillIfNeeded()`. `nil` before `prepare()`
    /// has run, or once no backfill was needed at all (already marked
    /// complete for this store file). Retained (not fire-and-forget) so
    /// `cancelImageContentHashBackfillForTesting()`/
    /// `waitForImageContentHashBackfillForTesting()` have something to act
    /// on, and so `deinit` can cancel a still-running pass rather than
    /// leaking it past this actor's own lifetime.
    private var imageContentHashBackfillTask: Task<Void, Never>?

    /// T-PF1 (D1 launch-latency fix): deliberately does NOT run the
    /// `normalizedText` backfill anymore — see `prepare()`'s doc comment for
    /// why, and why this initializer's signature is unchanged (every existing
    /// caller/test that constructs a store synchronously keeps compiling and
    /// keeps working, since normal insert/query paths never depended on the
    /// backfill having already run).
    ///
    /// - Parameters:
    ///   - modelContainer: Where records are persisted. Production code uses
    ///     `SwiftDataClipStore.makeProductionContainer()`; tests must pass a
    ///     container configured `isStoredInMemoryOnly: true` (or pointed at a
    ///     throwaway temp directory) — never the real on-disk container.
    ///   - blobStore: The shared `BlobStore` instance blob cleanup is routed
    ///     through on delete/clearHistory/enforceRetention, and (T-PF5c) an
    ///     image row's blob is re-read through on the background image-
    ///     contentHash backfill below.
    ///   - imagePixelHasher: T-PF5c — computes the format-independent,
    ///     decoded-pixel `contentHash` used by the background image-
    ///     contentHash backfill (`scheduleImageContentHashBackfillIfNeeded()`).
    ///     Defaulted to the production `CoreGraphicsImagePixelHasher()`
    ///     (mirroring `blobStore`'s own "always injected, production default
    ///     supplied here" shape) so `AppEnvironment`'s existing
    ///     `SwiftDataClipStore(modelContainer:blobStore:)` call site needs no
    ///     change; tests inject a fake to prove per-row gating without
    ///     depending on `CoreGraphicsImagePixelHasher`'s real decode/hash cost.
    public init(
      modelContainer: ModelContainer, blobStore: BlobStore,
      imagePixelHasher: any ImagePixelHashing = CoreGraphicsImagePixelHasher()
    ) {
      self.init(
        modelContainer: modelContainer, blobStore: blobStore, imagePixelHasher: imagePixelHasher,
        migrationStorage: UserDefaults.standard)
    }

    /// Test-only overload — injects `migrationStorage` (T-PF5c: where the
    /// image-contentHash backfill's one-shot marker is persisted) so a test
    /// can assert that marker's set-only-on-genuine-completion behavior
    /// without touching real `UserDefaults` I/O (mirrors
    /// `OneShotStoreMigrationTests.FakeOneShotMigrationStorage`'s identical
    /// rationale). Deliberately NOT `public`: `OneShotMigrationStorage`
    /// (`OneShotStoreMigration.swift`) is itself an internal, non-`public`
    /// protocol — Swift's access-control rules forbid a `public` API from
    /// exposing an internal type in its signature, so this initializer
    /// cannot be `public` either. `ClipnestCoreTests` (this same module, via
    /// `@testable import`) can still call it directly; `AppEnvironment` (the
    /// separate `ClipnestApp` module) always goes through the `public init`
    /// above instead, which always resolves `migrationStorage` to the real
    /// `UserDefaults.standard`.
    init(
      modelContainer: ModelContainer, blobStore: BlobStore,
      imagePixelHasher: any ImagePixelHashing,
      migrationStorage: OneShotMigrationStorage
    ) {
      self.modelContext = ModelContext(modelContainer)
      self.blobStore = blobStore
      self.imagePixelHasher = imagePixelHasher
      self.migrationStorage = migrationStorage
    }

    /// Cancels a still-running background image-contentHash backfill rather
    /// than letting it keep running past this actor's own lifetime — mostly
    /// matters for tests, which construct many short-lived stores; production
    /// `SwiftDataClipStore` instances live for the whole app process (owned
    /// by `AppEnvironment`), so this rarely fires there. `Task.cancel()` is
    /// safe to call from a non-isolated `deinit` (it's a plain, thread-safe
    /// operation on the task handle, not an actor-isolated call).
    deinit {
      imageContentHashBackfillTask?.cancel()
    }

    // MARK: - Production container

    private static let storeFileName = "ClipItems.store"

    /// The production on-disk container: `~/Library/Application
    /// Support/Clipnest/ClipItems.store` — the same base-directory family as
    /// `BlobStore.defaultBaseDirectory()`, INCLUDING that method's T-PF8
    /// `CLIPNEST_TEST_DATA_ROOT` override (see its doc comment): this method
    /// does no path resolution of its own, so redirecting `BlobStore
    /// .defaultBaseDirectory()` redirects this store's on-disk file too, with
    /// no separate plumbing. Never called by tests, EXCEPT
    /// `ProductionStoreIsolationTests`, which calls it only with that override
    /// set to a throwaway temp directory, specifically to prove this exact
    /// call chain honors the redirect — it never reaches the real
    /// `~/Library/Application Support/Clipnest` in that test either.
    ///
    /// Corrupt-store recovery (architecture-review finding): routed through
    /// `ModelContainerRecovery.openWithRecovery(...)` so a damaged/unreadable
    /// store file no longer throws straight through to `AppEnvironment.init`
    /// (which `AppDelegate` would otherwise turn into an unrecoverable launch
    /// crash) — see that type's doc comment for the full recovery design. This
    /// method's signature is unchanged (`() throws -> ModelContainer`), so
    /// callers need no changes; it now only throws for a genuinely
    /// unrecoverable failure (recovery's own retry also failed).
    public static func makeProductionContainer() throws -> ModelContainer {
      let baseDirectory = BlobStore.defaultBaseDirectory()
      do {
        try FileManager.default.createDirectory(
          at: baseDirectory, withIntermediateDirectories: true)
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
      let storeURL = baseDirectory.appendingPathComponent(storeFileName)
      do {
        return try ModelContainerRecovery.openWithRecovery(storeURL: storeURL, logger: logger) {
          let configuration = ModelConfiguration(url: storeURL)
          return try ModelContainer(for: ClipItemRecord.self, configurations: configuration)
        }
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    /// An `isStoredInMemoryOnly` container for tests — never touches disk, so
    /// tests never risk writing to the real
    /// `~/Library/Application Support/Clipnest`. `ClipItemRecord` is `private`
    /// to this file, so this factory (rather than a test-side literal) is the
    /// only way test code can construct a container for it.
    public static func makeTestContainer() throws -> ModelContainer {
      // In-memory test store — never touches the real Application Support store
      // and leaves nothing on disk. The explicit `Schema` keeps SwiftData from
      // inferring the model (and a store name) from `Bundle.main`. `swift test`
      // runs on the release job's Xcode 26 toolchain (see
      // `.github/workflows/release.yml`), where in-memory SwiftData works; the
      // older Xcode 16.x "Unable to determine Bundle Name" crash was resolved by
      // that runner, not by any workaround here.
      let schema = Schema([ClipItemRecord.self])
      let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      do {
        return try ModelContainer(for: schema, configurations: configuration)
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    /// Test-only: an on-disk (not `isStoredInMemoryOnly`) container at an
    /// explicit `url`, for tests that need a *real* store file — specifically,
    /// to prove a pre-`normalizedText` store file (one written before this
    /// attribute existed) migrates in-place without throwing. Never called by
    /// production code, which always uses `makeProductionContainer()`'s fixed
    /// path under `~/Library/Application Support/Clipnest`.
    public static func makeContainerForTesting(at url: URL) throws -> ModelContainer {
      // Explicit Schema so SwiftData maps the model directly rather than
      // inferring it via `Bundle.main`. See makeTestContainer().
      let schema = Schema([ClipItemRecord.self])
      let configuration = ModelConfiguration(schema: schema, url: url)
      do {
        return try ModelContainer(for: schema, configurations: configuration)
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    /// Test-only: exercises the exact same corrupt-store recovery path as
    /// `makeProductionContainer()` (see `ModelContainerRecovery
    /// .openWithRecovery(...)`) but against an explicit `url` instead of the
    /// fixed production path, so tests can prove recovery from a genuinely
    /// corrupt store file without ever touching `~/Library/Application
    /// Support/Clipnest`. Deliberately does NOT share an implementation with
    /// `makeContainerForTesting(at:)` above — that one must stay
    /// recovery-free so the pre-`normalizedText` migration tests keep proving
    /// a legitimately-migratable store is upgraded, not backed up/wiped. Never
    /// called by production code, which always goes through
    /// `makeProductionContainer()`.
    public static func makeRecoveringContainerForTesting(at url: URL) throws -> ModelContainer {
      do {
        return try ModelContainerRecovery.openWithRecovery(storeURL: url, logger: logger) {
          // Explicit Schema so SwiftData maps the model directly rather than
          // inferring it via `Bundle.main`. See makeTestContainer().
          let schema = Schema([ClipItemRecord.self])
          let configuration = ModelConfiguration(schema: schema, url: url)
          return try ModelContainer(for: schema, configurations: configuration)
        }
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    /// Test-only: inserts `item` directly into `container` with an **empty**
    /// `normalizedText`, bypassing `insertOrBumpDuplicate`'s normal
    /// `previewText.lowercased()` computation — simulates a row exactly as it
    /// looks the moment it migrates in from a pre-`normalizedText` on-disk
    /// store (see `ClipItemRecord.normalizedText`'s doc comment), so tests can
    /// prove `prepare()`'s backfill repairs it. `ClipItemRecord` is `private`
    /// to this file, so this factory is the only way test code can construct one
    /// directly. Never called by production code.
    public static func insertRecordWithEmptyNormalizedTextForTesting(
      _ item: ClipItem, in container: ModelContainer
    ) throws {
      let context = ModelContext(container)
      let record = ClipItemRecord(item)
      record.normalizedText = ""
      context.insert(record)
      do {
        try context.save()
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    /// Test-only: inserts `item` directly into `container` with
    /// `pixelContentHashMigrated` explicitly `false` — bypasses
    /// `insertOrBumpDuplicate`'s normal insert path, which marks a
    /// freshly-captured row `true` (see `ClipItemRecord
    /// .pixelContentHashMigrated`'s and `ClipItemRecord.init(_ item:)`'s doc
    /// comments) — simulating a row exactly as it looks the moment it
    /// migrates in from a pre-T-PF5c on-disk store, where `contentHash` is
    /// still the OLD raw-byte hash, so tests can prove
    /// `scheduleImageContentHashBackfillIfNeeded()`'s background pass repairs
    /// it. Mirrors `insertRecordWithEmptyNormalizedTextForTesting`'s identical
    /// shape/rationale immediately above, for the sibling backfill. `ClipItemRecord`
    /// is `private` to this file, so this factory is the only way test code
    /// can construct one directly. Never called by production code.
    public static func insertRecordNeedingImageContentHashBackfillForTesting(
      _ item: ClipItem, in container: ModelContainer
    ) throws {
      let context = ModelContext(container)
      let record = ClipItemRecord(item)
      record.pixelContentHashMigrated = false
      context.insert(record)
      do {
        try context.save()
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    // MARK: - Migration-crash fix: normalizedText backfill (T-PF1: one-shot, off `init`)

    private static let logger = ClipnestLogger(
      subsystem: ClipnestLog.subsystem, category: "SwiftDataClipStore")

    /// T-PF1 (D1 launch-latency fix): runs the one-time `normalizedText`
    /// backfill (see `backfillNormalizedText(in:)`) if — and only if — it has
    /// never completed for THIS on-disk store file before.
    ///
    /// Deliberately NOT run inside `init` anymore. `init` is a plain,
    /// non-`async` actor initializer: it cannot suspend, so its body always
    /// ran synchronously on whichever thread constructed the store — the
    /// **main thread**, since `AppEnvironment` used to build this store
    /// directly inside its own `@MainActor init` (see that type's doc
    /// comment). The backfill's unindexed `#Predicate` fetch scans the
    /// ENTIRE `ClipItemRecord` table with no `#Index` (macOS 14 deployment
    /// target — see `ClipItemRecord`'s doc comment), so this was a full
    /// sequential table scan blocking `applicationDidFinishLaunching` on
    /// every single launch. `prepare()` is `async`; `AppEnvironment.init`
    /// now calls it from a background `Task.detached`, so this scan — on the
    /// (rare) launch where it actually runs — never touches the main thread.
    ///
    /// One-shot, cross-launch: gated via the shared `OneShotStoreMigration
    /// .run(...)` helper (`OneShotStoreMigration.swift`, this same folder),
    /// keyed to `backfillCompleteDefaultsKeyPrefix` + the store's own on-disk
    /// file path — NOT a row in the store, since reading the store to check
    /// would require exactly the full-table scan this exists to eliminate.
    /// Correct for a store written by an older app version that predates this
    /// marker entirely: a legacy store has no marker key yet, so this
    /// backfills (and, only on genuine success, marks complete) exactly once
    /// — on the first launch after upgrading to this fix — never again after
    /// that.
    ///
    /// Reviewer finding (T-PF1 review): `backfillNormalizedText(in:)` now
    /// reports whether it genuinely succeeded, and `OneShotStoreMigration.run`
    /// only marks the migration complete on `true` — a transient failure
    /// (disk full, a momentary SQLite lock) during this one-shot scan no
    /// longer permanently marks it done; it simply retries on the next
    /// `prepare()` call (the next launch). See `OneShotStoreMigration.run`'s
    /// doc comment for the full rationale.
    ///
    /// T-PF5c (restructure — reviewer rejection): runs the (fast, metadata-
    /// only) `normalizedText` backfill synchronously, exactly as before, then
    /// only SCHEDULES the image `contentHash` backfill
    /// (`scheduleImageContentHashBackfillIfNeeded()`) and returns — it does
    /// NOT await that backfill's completion.
    ///
    /// This split is the actual fix for the rejection: measured against the
    /// real, staged `CoreGraphicsImagePixelHasher`, decode+hash cost ranged
    /// 10-82ms per image, so a synchronous pass over a 1000-item history (the
    /// default retention cap) took 15-82+ seconds. `AppEnvironment.init`
    /// `await`s both stores' `prepare()` calls before assigning
    /// `self.clipStore`/`self.snippetStore`, and `AppDelegate
    /// .launchEnvironment()` only calls `registerHotkey()`/`startCapture()`
    /// AFTER that assignment — so as long as `prepare()` used to await this
    /// backfill, the global hotkey, live capture, and the picker were all
    /// unreachable for that whole window, with zero user-visible feedback
    /// (Settings showed only "Starting Clipnest…"): indistinguishable from a
    /// hang. Since `prepare()` here no longer awaits ANY part of the image
    /// backfill, `AppEnvironment.init` — and therefore hotkey registration —
    /// is bounded only by the (fast, metadata-only) `normalizedText` scan,
    /// regardless of history size or image count.
    ///
    /// See `scheduleImageContentHashBackfillIfNeeded()`'s doc comment for how
    /// the image backfill itself is now per-row-persisted, cancellable, and
    /// resumable — it no longer goes through `OneShotStoreMigration.run(...)`
    /// at all (that helper's `migration` parameter is a plain, non-`async`
    /// `() -> Bool` closure by contract, which cannot `await` — exactly the
    /// constraint that forced the ORIGINAL, rejected version of this backfill
    /// to run fully synchronously in the first place).
    public func prepare() async {
      OneShotStoreMigration.run(
        keyPrefix: Self.backfillCompleteDefaultsKeyPrefix,
        storePath: storePathForOneShotMigration()
      ) {
        Self.backfillNormalizedText(in: modelContext)
      }

      scheduleImageContentHashBackfillIfNeeded()
    }

    /// P2-D (Linux port): `OneShotStoreMigration.swift` no longer imports
    /// SwiftData or knows about `ModelContext` — it takes a plain
    /// `storePath: String?` instead, so it stays reusable by the future
    /// Linux SQLite-backed `ClipStore`. This macOS-only file is where the
    /// derivation now lives: `nil` for an `isStoredInMemoryOnly` container
    /// (every container `ClipnestCoreTests` builds via `makeTestContainer()`)
    /// — there is no persisted "already done, on a LATER launch" for a store
    /// that dies with the process — otherwise the container's own configured
    /// on-disk file path. Mirrors `SwiftDataSnippetStore
    /// .storePathForOneShotMigration()`'s identical shape; this small (~6
    /// line) duplication across exactly these two macOS-only files is a
    /// deliberate, DOCUMENTED exception to coding-standards.md's DRY rule —
    /// same rationale as `imageContentHashBackfillCompletionKey()` just
    /// below: extracting it would require a new shared macOS-only helper
    /// file, out of scope for this task.
    private func storePathForOneShotMigration() -> String? {
      guard let configuration = modelContext.container.configurations.first,
        !configuration.isStoredInMemoryOnly
      else { return nil }
      return configuration.url.path
    }

    /// Prefix for the per-store-file `UserDefaults` completion-marker key —
    /// exposed (mirroring `ModelContainerRecovery.backupSuffixPrefix`) so
    /// test code can compute and clean up the exact key it wrote, instead of
    /// re-hardcoding the literal a second time (coding-standards.md: no
    /// magic string duplicated across production and test code). Passed to
    /// `OneShotStoreMigration.run` as this backfill's `keyPrefix`.
    static let backfillCompleteDefaultsKeyPrefix =
      "ClipnestCore.SwiftDataClipStore.normalizedTextBackfillComplete."

    /// One-time backfill for rows that migrated in with `normalizedText`
    /// defaulted to `""` — the lightweight-migration default that lets an
    /// existing on-disk store (written before `normalizedText` existed) open
    /// at all (see `ClipItemRecord.normalizedText`'s doc comment). Those rows
    /// persist fine but are invisible to `query(text:...)`'s substring match
    /// until repaired.
    ///
    /// Called from `prepare()`, guarded by that method's persisted one-shot
    /// marker (via `OneShotStoreMigration.run`) — this is NOT "cheap to just
    /// re-run on every launch" (correcting an earlier version of this
    /// comment, which claimed running this unconditionally every launch was
    /// fine because the predicate matches nothing once every row is
    /// backfilled). It is not cheap: with no `#Index` on
    /// `normalizedText`/`previewText` (macOS 14 deployment target), SQLite
    /// must scan every row to confirm zero matches — an unbounded full-table
    /// scan, every launch, forever, not just the first one after upgrading.
    /// The marker is what actually makes this one-shot.
    ///
    /// Best-effort: a failure here must never surface as a hard error (there
    /// is no safe fallback for the caller), so it's logged (metadata only,
    /// per coding-standards.md — never `previewText`) and swallowed rather
    /// than thrown. Instead, it reports success/failure via its `Bool`
    /// return: `OneShotStoreMigration.run` only marks the migration complete
    /// when this returns `true`, so a fetch/save failure here is NOT
    /// permanently (and silently) marked done — the next `prepare()` call
    /// (the next launch) retries it. Returns `true` for "nothing needed
    /// backfilling" (no stale rows found) exactly as it would for "backfilled
    /// successfully" — both are a genuinely completed pass.
    private static func backfillNormalizedText(in modelContext: ModelContext) -> Bool {
      let predicate = #Predicate<ClipItemRecord> {
        $0.normalizedText == "" && $0.previewText != ""
      }
      let descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
      let staleRecords: [ClipItemRecord]
      do {
        staleRecords = try modelContext.fetch(descriptor)
      } catch {
        logger.error(
          "SwiftDataClipStore: normalizedText backfill fetch failed (\(String(describing: error)))"
        )
        return false
      }
      guard !staleRecords.isEmpty else { return true }

      for record in staleRecords {
        record.normalizedText = ClipItemRecord.computeNormalizedText(
          previewText: record.previewText, ocrText: record.ocrText)
      }
      do {
        try modelContext.save()
        return true
      } catch {
        logger.error(
          "SwiftDataClipStore: normalizedText backfill save failed (\(String(describing: error)))"
        )
        return false
      }
    }

    // MARK: - Image contentHash backfill (T-PF5c: decoded-pixel hash, D44/D45; restructured after reviewer rejection)

    /// Prefix for this backfill's own `UserDefaults` completion-marker key —
    /// deliberately DISTINCT from `backfillCompleteDefaultsKeyPrefix` above,
    /// so this migration and the `normalizedText` one are gated fully
    /// independently even though they share the same on-disk store file:
    /// completing one never marks the other complete, and either can retry
    /// on its own after a failure without affecting the other. `static` (not
    /// `private`), matching `backfillCompleteDefaultsKeyPrefix`, so test code
    /// can compute the exact key it wrote instead of re-hardcoding the
    /// literal. Same literal as before this restructure — existing callers
    /// (including this file's own tests) that reference it keep working
    /// unchanged.
    static let imageContentHashBackfillCompleteDefaultsKeyPrefix =
      "ClipnestCore.SwiftDataClipStore.imageContentHashBackfillComplete."

    /// Upgrades every already-captured `.image` row's `contentHash` from the
    /// OLD raw-encoded-bytes hash (`BlobStore.contentHash(of:)`, computed
    /// once at capture time by `PasteboardReader`, before this migration
    /// existed) to the NEW format-independent, decoded-pixel hash
    /// (`ImagePixelHashing.pixelContentHash(of:)`) — see
    /// `ImagePixelHashing.swift`'s doc comment for why the switch happened
    /// (PNG vs TIFF capture of the same picture used to hash differently and
    /// defeat dedup).
    ///
    /// REJECTED-AND-RESTRUCTURED (see `ImageContentHashBackfillCoordinator
    /// .swift`'s top doc comment for the full before/after): the original
    /// version of this ran fully synchronously inside `prepare()`, gated by
    /// `OneShotStoreMigration.run(...)`'s sync-only `() -> Bool` contract —
    /// measured at 10-82ms of decode+hash PER IMAGE against the real
    /// `CoreGraphicsImagePixelHasher`, which made `prepare()` (and therefore
    /// `AppEnvironment.init`, and therefore hotkey/capture/picker readiness)
    /// block for 15-82+ seconds at the default 1000-item retention cap, with
    /// a single end-of-batch save that lost all progress on a force-quit.
    ///
    /// This method instead only SCHEDULES a background `ImageContentHashBackfillCoordinator`
    /// run and returns immediately — called from `prepare()`, which does not
    /// await it. Fixes every part of the rejection:
    /// - **Never gates readiness**: does not block `prepare()`, so it cannot
    ///   block `AppEnvironment.init`/hotkey registration/capture/the picker
    ///   regardless of history size or per-image decode cost.
    /// - **Per-item persistence, not one batched save**: `migrateOneImageContentHash(_:)`
    ///   below calls `save()` after EACH row, so a force-quit mid-run leaves
    ///   every already-processed row's new hash durably on disk.
    /// - **Cancellable and yields**: the coordinator checks `Task.isCancelled`
    ///   before each item (see its doc comment), and the actual slow work —
    ///   `blobStore.read` + `hasher.pixelContentHash` — runs inside a
    ///   `Task.detached` per item (`migrateOneImageContentHash(_:)`), exactly
    ///   like `enforceRetention`'s existing `Task.detached`-offloaded blob
    ///   deletion (T-PF1's fix for the identical class of problem). That
    ///   `await` is a genuine suspension point: this actor is free for the
    ///   whole duration of each item's blob read/hash, so a `query(...)`
    ///   call queued behind this migration is never stuck waiting a whole
    ///   item's decode+hash time, let alone the whole run's — see
    ///   `SwiftDataClipStoreTests.queryIsNotBlockedBehindEnforceRetentionsInFlightBlobDeletion`
    ///   for the sibling proof of this exact yielding mechanism against
    ///   `enforceRetention`.
    /// - **Resumable without redoing completed rows**: tracked per-row via
    ///   the new, additive `ClipItemRecord.pixelContentHashMigrated` flag
    ///   (see that property's doc comment) instead of a single store-wide
    ///   marker — `fetchImageContentHashBackfillCandidates()` only ever
    ///   returns rows still flagged `false`, so a row this migration already
    ///   resolved (migrated OR permanently skipped) never becomes a candidate
    ///   again, on this run or any future one, with no separate cursor/queue
    ///   to persist.
    ///
    /// Failure semantics carried over UNCHANGED from the accepted design
    /// (T-PF5c requirement 4):
    /// - A missing blob (`BlobStoreError.notFound`) is PERMANENT — logged
    ///   (metadata-only) and the row is flagged resolved (via
    ///   `markPermanentlyResolved(_:)`) without changing its `contentHash`,
    ///   so it counts as progress and is never retried.
    /// - A decode failure (`hasher.pixelContentHash` returns `nil`) is also
    ///   PERMANENT for the same reason and handled identically.
    /// - Any OTHER blob read failure (`BlobStoreError.ioFailure`/any other
    ///   thrown error — a disk error, a momentary lock, anything that isn't
    ///   "the file doesn't exist") is POTENTIALLY TRANSIENT: the row is left
    ///   unresolved (`pixelContentHashMigrated` stays `false`) so a later run
    ///   retries it, and this run reports `.completedWithTransientFailures`
    ///   rather than `.completedCleanly` — see
    ///   `ImageContentHashBackfillRunResult`'s doc comment.
    ///
    /// WHAT "COMPLETE" MEANS HERE (T-PF5c requirement 5): the persisted
    /// one-shot marker (`imageContentHashBackfillCompleteDefaultsKeyPrefix`)
    /// is set — via `markImageContentHashBackfillComplete()` — ONLY when the
    /// coordinator's `run(...)` call returns `.completedCleanly`: every
    /// candidate fetched at the start of THIS run was attempted, none was
    /// cancelled, and none reported a transient failure. A cancelled run
    /// (`.cancelled`) or one with any transient failure
    /// (`.completedWithTransientFailures`) never sets it — so a marker can
    /// never claim "done" while a row is still stranded unmigrated (the
    /// literal failure mode this requirement calls out: "a marker that says
    /// 'done' after a cancelled run would strand rows permanently").
    /// Concretely: the marker is a pure PERFORMANCE optimization ("this store
    /// file's candidate scan may be skipped forever") layered on top of the
    /// per-row `pixelContentHashMigrated` flag, which is the actual source of
    /// correctness — even if the marker were somehow never set, re-running
    /// the (increasingly cheap, since it only ever shrinks) candidate scan on
    /// every future launch would still converge to every row being correctly
    /// migrated; the marker only saves that repeat scan once truly done.
    private func scheduleImageContentHashBackfillIfNeeded() {
      guard !hasImageContentHashBackfillCompletedForThisStoreFile() else { return }
      // Guards against a hypothetical double-`prepare()` call leaking a
      // second, overlapping background pass — never expected in production
      // (see `AppEnvironment.init`'s single `prepare()` call per store), but
      // cheap insurance, and lets a test call `prepare()` more than once
      // safely.
      imageContentHashBackfillTask?.cancel()
      imageContentHashBackfillTask = Task { [weak self] in
        guard let self else { return }
        let coordinator = ImageContentHashBackfillCoordinator(
          fetchCandidates: { [weak self] in
            try await self?.fetchImageContentHashBackfillCandidates() ?? []
          },
          migrateItem: { [weak self] item in
            guard let self else { return .permanentlySkipped }
            return await self.migrateOneImageContentHash(item)
          }
        )
        // No progress consumer in production today — this migration is a
        // silent background pass, with no Settings UI (unlike T-UX1's
        // user-triggered `OCRBackfillCoordinator`). The hook exists purely
        // because `ImageContentHashBackfillCoordinator.run(...)` mirrors
        // `OCRBackfillCoordinator.run(...)`'s shape (this task's own
        // instruction); tests use it to assert the exact progress sequence.
        let result = await coordinator.run(onProgress: { _ in })
        if case .completedCleanly = result {
          await self.markImageContentHashBackfillComplete()
        }
      }
    }

    /// The current work set for the image-contentHash backfill: every
    /// `.image` row with a blob that hasn't been resolved (migrated OR
    /// permanently skipped) yet — see `ClipItemRecord.pixelContentHashMigrated`'s
    /// doc comment. Re-fetched fresh on every coordinator `run(...)` call (see
    /// `ImageContentHashCandidateProvider`'s doc comment), so this naturally
    /// shrinks as rows are resolved; no separate cursor/offset is persisted.
    private func fetchImageContentHashBackfillCandidates() throws -> [PendingImageContentHashItem] {
      let imageKindRawValue = ItemKind.image.rawValue
      let predicate = #Predicate<ClipItemRecord> {
        $0.kindRawValue == imageKindRawValue && $0.blobPath != nil
          && $0.pixelContentHashMigrated == false
      }
      let records = try fetch(
        predicate: predicate, sortedBy: SortDescriptor(\ClipItemRecord.createdAt, order: .reverse))
      return records.compactMap { record in
        // The predicate above already guarantees `blobPath != nil`, but this
        // avoids a force-unwrap of the optional per coding-standards.md.
        guard let blobPath = record.blobPath else { return nil }
        return PendingImageContentHashItem(id: record.id, blobPath: blobPath)
      }
    }

    /// Migrates exactly one candidate: reads its blob and computes its
    /// decoded-pixel hash OFF this actor (inside `Task.detached`, mirroring
    /// `enforceRetention`'s identical offload of its own blob I/O — see this
    /// method's use in `scheduleImageContentHashBackfillIfNeeded()`'s doc
    /// comment for why that `await` is what lets a concurrent `query(...)`
    /// run in between items), then hops back onto this actor to persist the
    /// result via `applyMigratedHash(_:to:)`/`markPermanentlyResolved(_:)`.
    private func migrateOneImageContentHash(
      _ item: PendingImageContentHashItem
    ) async -> ImageContentHashBackfillOutcome {
      let blobStore = self.blobStore
      let hasher = self.imagePixelHasher
      let blobPath = item.blobPath

      let hashResult = await Task.detached(priority: .utility) { () -> ImageBlobHashResult in
        let blobData: Data
        do {
          blobData = try blobStore.read(blobPath: blobPath)
        } catch BlobStoreError.notFound {
          return .missingOrUndecodable
        } catch {
          return .transientReadFailure
        }
        guard let pixelHash = hasher.pixelContentHash(of: blobData) else {
          return .missingOrUndecodable
        }
        return .hash(pixelHash)
      }.value

      switch hashResult {
      case .hash(let pixelHash):
        return applyMigratedHash(pixelHash, to: item.id)
      case .missingOrUndecodable:
        Self.logger.error(
          "SwiftDataClipStore: image contentHash backfill permanently skipped a row — blob missing or undecodable, not retried"
        )
        return markPermanentlyResolved(item.id)
      case .transientReadFailure:
        Self.logger.error(
          "SwiftDataClipStore: image contentHash backfill blob read failed — treating as transient, will retry"
        )
        return .transientFailure
      }
    }

    /// Persists a successful re-hash for one row and marks it resolved.
    /// Missing (deleted mid-run, matching `OCRBackfillCoordinator
    /// .recognizeAndStore(_:quality:)`'s identical precedent) is treated as a
    /// permanent skip: there is no row left to ever revisit.
    private func applyMigratedHash(_ pixelHash: String, to id: UUID)
      -> ImageContentHashBackfillOutcome
    {
      let record: ClipItemRecord?
      do {
        record = try fetchRecord(id: id)
      } catch {
        Self.logger.error(
          "SwiftDataClipStore: image contentHash backfill re-fetch failed — treating as transient (\(String(describing: error)))"
        )
        return .transientFailure
      }
      guard let record else { return .permanentlySkipped }

      record.contentHash = pixelHash
      record.pixelContentHashMigrated = true
      do {
        try save()
        return .migrated
      } catch {
        Self.logger.error(
          "SwiftDataClipStore: image contentHash backfill per-item save failed — treating as transient (\(String(describing: error)))"
        )
        return .transientFailure
      }
    }

    /// Flags a row resolved WITHOUT changing its `contentHash` — the missing-
    /// blob/undecodable-blob permanent-skip path. Missing (deleted mid-run)
    /// is itself just a permanent skip: nothing is left to flag.
    private func markPermanentlyResolved(_ id: UUID) -> ImageContentHashBackfillOutcome {
      let record: ClipItemRecord?
      do {
        record = try fetchRecord(id: id)
      } catch {
        Self.logger.error(
          "SwiftDataClipStore: image contentHash backfill re-fetch (permanent-skip path) failed — treating as transient (\(String(describing: error)))"
        )
        return .transientFailure
      }
      guard let record else { return .permanentlySkipped }

      record.pixelContentHashMigrated = true
      do {
        try save()
        return .permanentlySkipped
      } catch {
        Self.logger.error(
          "SwiftDataClipStore: image contentHash backfill permanent-skip save failed — treating as transient (\(String(describing: error)))"
        )
        return .transientFailure
      }
    }

    /// `nil` for an `isStoredInMemoryOnly` container, matching
    /// `OneShotStoreMigration`'s own (private, so not reusable from here)
    /// `completionKey(keyPrefix:modelContext:)` — an in-memory store dies with
    /// the process, so there is no persisted "already done, on a LATER
    /// launch" to track. This small duplication (~8 lines, vs. that helper's
    /// private key/hasCompleted/markComplete trio) is a deliberate, DOCUMENTED
    /// exception to coding-standards.md's DRY rule: `OneShotStoreMigration
    /// .run(...)`'s `migration` parameter is contractually synchronous
    /// (`() -> Bool`), which this migration can no longer be (see
    /// `scheduleImageContentHashBackfillIfNeeded()`'s doc comment), and this
    /// task's scope does not include modifying `OneShotStoreMigration.swift`.
    /// If that helper ever grows an async-friendly variant, this should be
    /// the first caller migrated to it.
    private func imageContentHashBackfillCompletionKey() -> String? {
      guard let configuration = modelContext.container.configurations.first,
        !configuration.isStoredInMemoryOnly
      else { return nil }
      return Self.imageContentHashBackfillCompleteDefaultsKeyPrefix + configuration.url.path
    }

    private func hasImageContentHashBackfillCompletedForThisStoreFile() -> Bool {
      guard let key = imageContentHashBackfillCompletionKey() else { return false }
      return migrationStorage.bool(forKey: key)
    }

    private func markImageContentHashBackfillComplete() {
      guard let key = imageContentHashBackfillCompletionKey() else { return }
      migrationStorage.set(true, forKey: key)
    }

    /// Test-only: awaits the in-flight (or already-finished) background
    /// image-contentHash backfill `prepare()` started, if any — lets a test
    /// assert on its outcome deterministically instead of guessing with a
    /// sleep. Never called by production code: `AppEnvironment` never needs
    /// this migration's completion — that is the entire point of this
    /// restructure (see `prepare()`'s doc comment).
    public func waitForImageContentHashBackfillForTesting() async {
      await imageContentHashBackfillTask?.value
    }

    /// Test-only: cancels the in-flight background image-contentHash
    /// backfill, if any — simulates the app quitting mid-migration (a real
    /// force-quit can't be driven from within a unit-test process). Combine
    /// with `waitForImageContentHashBackfillForTesting()` to await the
    /// now-cancelled run's actual stop.
    public func cancelImageContentHashBackfillForTesting() {
      imageContentHashBackfillTask?.cancel()
    }

    // MARK: - ClipStore

    public func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
      if let existing = try fetchRecord(contentHash: item.contentHash) {
        // Bump only `createdAt`, matching `InMemoryClipStore`'s dedup rule —
        // the rest of the existing row (in particular `pinned`) is preserved,
        // not overwritten by the incoming duplicate's fields.
        existing.createdAt = item.createdAt
        try save()
        return existing.asClipItem()
      }

      let record = ClipItemRecord(item)
      modelContext.insert(record)
      try save()
      return record.asClipItem()
    }

    public func fetchAll() async throws -> [ClipItem] {
      // Unbounded/unfiltered by design — see the protocol's doc comment.
      // `query(text:kind:scope:offset:limit:)` (T49) is the real, filtered/
      // paged path the picker actually uses.
      try fetch(sortedBy: SortDescriptor(\ClipItemRecord.createdAt, order: .reverse))
        .map { $0.asClipItem() }
    }

    public func fetchPinned() async throws -> [ClipItem] {
      let predicate = #Predicate<ClipItemRecord> { $0.pinned == true }
      return try fetch(
        predicate: predicate, sortedBy: SortDescriptor(\ClipItemRecord.createdAt, order: .reverse)
      )
      .map { $0.asClipItem() }
    }

    public func query(
      text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
    ) async throws -> [ClipItem] {
      let lowercasedText = text.lowercased()
      let hasText = !lowercasedText.isEmpty
      let hasKind = kind != nil
      let kindRawValue = kind?.rawValue ?? ""
      let wantsPinned = scope == .pinned

      let predicate = #Predicate<ClipItemRecord> { record in
        record.pinned == wantsPinned
          && (!hasText || record.normalizedText.contains(lowercasedText))
          && (!hasKind || record.kindRawValue == kindRawValue)
      }

      switch scope {
      case .history:
        var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\ClipItemRecord.createdAt, order: .reverse)]
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try fetch(descriptor: descriptor).map { $0.asClipItem() }

      case .pinned:
        // `pinnedAt` is optional: rows pinned before this field existed have
        // `pinned == true, pinnedAt == nil` (a "legacy pinned row" — see
        // `ClipItemRecord.pinnedAt`'s and `InMemoryClipStore.query`'s doc
        // comments, and `ClipStoreContractTests
        // .queryPinnedScopeOrdersLegacyNilPinnedAtBeforeDatedPins`, M-3). This
        // used to push `SortDescriptor(\.pinnedAt, order: .forward)` down to
        // `FetchDescriptor` and trust its nil-handling; empirically that
        // *does* already sort `nil` first (verified against reversed
        // insertion order, multiple mixed dated/nil rows, and pagination
        // boundaries — Foundation's `OptionalComparator` treats `nil` as
        // ordered-ascending under `.forward`), but that's an internal
        // Foundation/SwiftData behavior, not a documented contract of
        // `FetchDescriptor`'s SQL pushdown specifically — nothing pins it to
        // stay that way across a SwiftData/Core Data version. Rather than
        // depend on it, fetch the (small — user-authored pins, not full
        // history) pinned set predicate-filtered only, and sort explicitly in
        // Swift with the exact same rule `InMemoryClipStore.query` uses
        // (`($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast)`),
        // so both `ClipStore` conformances are guaranteed byte-for-byte
        // identical regardless of any framework internal. Offset/limit are
        // applied here, in Swift, after this sort — they can't be pushed
        // down to `FetchDescriptor.fetchOffset/fetchLimit` (SQL-level) since
        // the correct order can only be established post-coalesce.
        let descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
        let records = try fetch(descriptor: descriptor)
        let sorted = records.sorted {
          ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast)
        }
        guard offset < sorted.count else { return [] }
        return Array(sorted[offset...].prefix(limit)).map { $0.asClipItem() }
      }
    }

    public func setPinned(_ id: UUID, pinned: Bool) async throws {
      guard let record = try fetchRecord(id: id) else { throw ClipStoreError.notFound }
      record.pinned = pinned
      // `pinnedAt` tracks *when* this pin took effect — set on pin, cleared
      // on unpin — so the picker's pinned group can order by pin time rather
      // than copy time. See `ClipItem.pinnedAt`'s doc comment.
      record.pinnedAt = pinned ? Date() : nil
      try save()
    }

    /// T-OCR2: records `text` as `id`'s recognized (OCR) text, and recomputes
    /// `normalizedText` so `query(text:...)`'s existing substring predicate
    /// finds it too, with no predicate change — see `ClipItemRecord
    /// .computeNormalizedText(previewText:ocrText:)`'s doc comment for why
    /// that derivation lives in exactly one place rather than being
    /// re-inlined here.
    /// - Throws: `ClipStoreError.notFound` if no item with that `id` exists.
    public func setRecognizedText(_ id: UUID, text: String) async throws {
      guard let record = try fetchRecord(id: id) else { throw ClipStoreError.notFound }
      record.ocrText = text
      record.normalizedText = ClipItemRecord.computeNormalizedText(
        previewText: record.previewText, ocrText: text)
      try save()
    }

    /// T-UX1: see `ClipStore.fetchImagesNeedingRecognition()`'s doc comment.
    public func fetchImagesNeedingRecognition() async throws -> [ClipItem] {
      let imageKindRawValue = ItemKind.image.rawValue
      // `(record.ocrText ?? "") == ""` is `ocrText == nil || ocrText == ""`
      // without the `||` — the un-simplified form made the type-checker time
      // out (`#Predicate`'s macro-expanded expression tree grows fast with
      // nested boolean operators over optionals); this form type-checks
      // instantly and is exactly equivalent.
      let predicate = #Predicate<ClipItemRecord> { record in
        record.kindRawValue == imageKindRawValue && record.blobPath != nil
          && (record.ocrText ?? "") == ""
      }
      return try fetch(
        predicate: predicate, sortedBy: SortDescriptor(\ClipItemRecord.createdAt, order: .reverse)
      )
      .map { $0.asClipItem() }
    }

    public func delete(_ id: UUID) async throws {
      guard let record = try fetchRecord(id: id) else { throw ClipStoreError.notFound }
      let item = record.asClipItem()
      modelContext.delete(record)
      try save()
      try deleteBlobs(for: [item], using: blobStore)
    }

    public func clearHistory() async throws {
      let records = try fetch(sortedBy: SortDescriptor(\ClipItemRecord.createdAt))
      let items = records.map { $0.asClipItem() }
      for record in records { modelContext.delete(record) }
      try save()
      try deleteBlobs(for: items, using: blobStore)
    }

    public func enforceRetention(cap: RetentionCap?) async throws {
      guard let cap else { return }

      let unpinnedPredicate = #Predicate<ClipItemRecord> { $0.pinned == false }
      let records: [ClipItemRecord]
      switch cap {
      case .maxCount(let maxCount):
        // T-PF1 (D2 fix): count first via `fetchCount` (pushed down to a SQL
        // `COUNT`, no `ClipItemRecord` materialization at all) instead of
        // fetching every unpinned row just to call `.count` on the array in
        // Swift. Only once we know there IS an excess do we fetch — and then
        // fetch ONLY the oldest `excess` rows directly via `fetchLimit`
        // (ascending `createdAt`, so the first `excess` rows returned are
        // exactly the ones `enforceRetention` deletes), never the whole
        // unpinned table. Default cap is 1000 (`SettingsStore
        // .defaultItemCount`) — before this fix, steady state materialized
        // ~1000 records on every capture AND at every launch.
        var descriptor = FetchDescriptor<ClipItemRecord>(predicate: unpinnedPredicate)
        let unpinnedCount = try fetchCount(descriptor: descriptor)
        let excess = unpinnedCount - maxCount
        if excess > 0 {
          descriptor.sortBy = [SortDescriptor(\ClipItemRecord.createdAt, order: .forward)]
          descriptor.fetchLimit = excess
          records = try fetch(descriptor: descriptor)
        } else {
          records = []
        }
      case .maxAge(let maxAge):
        let cutoff = Date().addingTimeInterval(-maxAge)
        let oldUnpinnedPredicate = #Predicate<ClipItemRecord> {
          $0.pinned == false && $0.createdAt < cutoff
        }
        records = try fetch(predicate: oldUnpinnedPredicate)
      }

      guard !records.isEmpty else { return }
      let items = records.map { $0.asClipItem() }
      for record in records { modelContext.delete(record) }
      try save()
      // T-PF1 (D2 fix): `deleteBlobs` does up to `records.count` synchronous
      // `FileManager.removeItem` calls (`ClipStore.swift`) — running it
      // in-line here used to hold this actor for the whole duration, queuing
      // every other call already waiting on it (in particular the picker's
      // `query(...)`, called from the exact same actor — see this task's
      // report for the full diagnosis). `Task.detached` moves that file I/O
      // onto a background thread; `await`ing it releases this actor's
      // exclusivity for the duration (a suspended actor call lets other
      // already-queued calls on the SAME actor run), so a `query` landing
      // during blob cleanup is no longer stuck behind it. Still `try await`ed
      // (not fire-and-forget) so `enforceRetention`'s existing contract is
      // unchanged from the CALLER's point of view — blobs are gone by the
      // time this call returns, matching `ClipStoreContractTests
      // .enforceRetentionDeletesTrimmedBlobs`'s immediate-after assertion,
      // which this task's report flags as unsafe to relax (owned by a
      // sibling agent's `ClipStore.swift`, not this file).
      let blobStore = self.blobStore
      try await Task.detached(priority: .utility) {
        try deleteBlobs(for: items, using: blobStore)
      }.value
    }

    // MARK: - Fetch/save helpers

    private func fetchRecord(id: UUID) throws -> ClipItemRecord? {
      let predicate = #Predicate<ClipItemRecord> { $0.id == id }
      var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
      descriptor.fetchLimit = 1
      return try fetch(descriptor: descriptor).first
    }

    private func fetchRecord(contentHash: String) throws -> ClipItemRecord? {
      let predicate = #Predicate<ClipItemRecord> { $0.contentHash == contentHash }
      var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
      descriptor.fetchLimit = 1
      return try fetch(descriptor: descriptor).first
    }

    private func fetch(
      predicate: Predicate<ClipItemRecord>? = nil,
      sortedBy sortDescriptor: SortDescriptor<ClipItemRecord>? = nil
    ) throws -> [ClipItemRecord] {
      var descriptor = FetchDescriptor<ClipItemRecord>(predicate: predicate)
      if let sortDescriptor { descriptor.sortBy = [sortDescriptor] }
      return try fetch(descriptor: descriptor)
    }

    private func fetch(descriptor: FetchDescriptor<ClipItemRecord>) throws -> [ClipItemRecord] {
      do {
        return try modelContext.fetch(descriptor)
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    /// `ModelContext.fetchCount(_:)` pushes the count down to a SQL `COUNT`
    /// rather than materializing matching rows into `ClipItemRecord`
    /// instances — used by `enforceRetention(cap:)`'s `.maxCount` branch
    /// (T-PF1/D2) so computing "how many unpinned rows exist" never
    /// allocates a single `ClipItemRecord`.
    private func fetchCount(descriptor: FetchDescriptor<ClipItemRecord>) throws -> Int {
      do {
        return try modelContext.fetchCount(descriptor)
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }

    private func save() throws {
      do {
        try modelContext.save()
      } catch {
        throw ClipStoreError.ioFailure(underlying: String(describing: error))
      }
    }
  }

  // MARK: - ClipItemRecord (private @Model entity)

  /// The private SwiftData entity backing `SwiftDataClipStore`. Mirrors every
  /// field of `ClipItem` — never referenced outside this file, and never
  /// returned from any `ClipStore` method; see the type's file-level doc
  /// comment and project-context.md decision D6.
  ///
  /// `kind` is stored as its raw `String` value (`kindRawValue`) rather than
  /// `ItemKind` directly, so this entity has no dependency on `ItemKind`'s
  /// SwiftData storage representation — a plain, unambiguous mapping in
  /// `asClipItem()`/`init(_:)` instead.
  ///
  /// `pinnedAt` is an *additive optional* field (added after this entity's
  /// first release) — SwiftData's lightweight migration handles this
  /// automatically (new optional properties default to `nil` on existing
  /// rows, no `VersionedSchema`/migration plan required); see the pin-order
  /// fix's report entry for confirmation this built + ran clean with no
  /// migration errors against the existing on-disk store shape.
  ///
  /// `#Index`/`#Unique` on `normalizedText`/`createdAt`/`pinned` was considered
  /// to speed up `query(...)`'s `#Predicate` scans, but skipped: those macros
  /// require macOS 15+, and this project's deployment target is macOS 14 (see
  /// coding-standards.md — never raised without a logged architect decision).
  /// `FetchDescriptor.fetchOffset`/`fetchLimit` in `query(...)` bound the scan
  /// cost instead.
  @Model
  private final class ClipItemRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var kindRawValue: String
    var previewText: String
    /// `previewText.lowercased()`, stored so `query(...)`'s `#Predicate` can
    /// do a case-insensitive substring match with plain `.contains` (SwiftData
    /// predicates can't call `.lowercased()` inline). "Kept in sync" only
    /// means "set once, at construction": `previewText` is never mutated after
    /// insert anywhere in this file today (only `insertOrBumpDuplicate` sets
    /// it, on insert), so there is no existing update path that would need to
    /// also update this field.
    ///
    /// Migration-crash fix: the `= ""` default is required, not decorative.
    /// This attribute was added after this entity's first release (like
    /// `pinnedAt` above), but unlike `pinnedAt` it is **non-optional** — and
    /// SwiftData's lightweight migration only auto-migrates a new non-optional
    /// attribute if it has a default value to backfill existing rows with
    /// (mirrors Core Data's lightweight-migration rule: a new required
    /// attribute must be optional *or* defaulted). Shipping this without a
    /// default crashed launch for every existing on-disk store —
    /// `NSCocoaErrorDomain 134110`, "Cannot migrate store in-place: ...
    /// missing attribute values on mandatory destination attribute" — because
    /// `ModelContainer` creation threw, `AppEnvironment.init` propagated it,
    /// and `AppDelegate` terminated the app (see the migration-fix report,
    /// `.superpowers/sdd/2026-08-06-clipnest-plan/migration-fix-report.md`).
    /// The default alone only makes migration *succeed*; it leaves every
    /// migrated-in row with `normalizedText == ""` (unsearchable) until
    /// `SwiftDataClipStore.prepare()`'s one-time backfill (see
    /// `backfillNormalizedText(in:)`) repairs it — moved out of `init` in
    /// T-PF1 (launch-latency fix); see `prepare()`'s doc comment.
    var normalizedText: String = ""
    var contentHash: String
    var pinned: Bool
    var pinnedAt: Date?
    var sourceAppName: String?
    var sourceBundleID: String?
    var byteSize: Int
    var blobPath: String?
    var fileReference: String?
    /// T-OCR1: on-device OCR text recognized from a `.image` item's pixels —
    /// mirrors `ClipItem.ocrText`'s doc comment. An *additive optional* field
    /// (added after this entity's first release), exactly like `pinnedAt`
    /// above: SwiftData's lightweight migration defaults it to `nil` on
    /// existing rows automatically, no `VersionedSchema`/migration plan or
    /// backfill needed for THIS field itself — unlike `normalizedText`
    /// (non-optional, defaulted, and requires a backfill because it's used in
    /// a `#Predicate` scan), `nil` is already the semantically correct value
    /// for "recognition hasn't run on this row" and needs no repair.
    var ocrText: String?
    /// T-PF5c (restructure): durable, per-row progress marker for the image
    /// `contentHash` backfill (`SwiftDataClipStore
    /// .fetchImageContentHashBackfillCandidates()`/`migrateOneImageContentHash(_:)`)
    /// — `true` once this row's `contentHash` is known to already be the
    /// current decoded-pixel hash, whether because the backfill genuinely
    /// re-hashed it, OR because it was permanently, unretryably skipped (a
    /// missing/undecodable blob — see `ImageContentHashBackfillOutcome
    /// .permanentlySkipped`'s doc comment), OR because it was inserted
    /// through the normal capture path (`insertOrBumpDuplicate`), whose
    /// `ClipItem.contentHash` is ALREADY the decoded-pixel hash by the time
    /// it reaches this store (computed upstream, in `PasteboardReader`,
    /// outside this file — an already-accepted assumption this migration
    /// depends on but does not itself verify).
    ///
    /// This is what makes the backfill RESUMABLE with no separate persisted
    /// cursor/queue: `fetchImageContentHashBackfillCandidates()`'s predicate
    /// is simply `pixelContentHashMigrated == false`, so a row this migration
    /// already resolved — on this launch or any earlier one — never becomes a
    /// candidate again, and a cancelled/interrupted run's un-reached rows
    /// remain exactly as findable as they were before the run started. An
    /// *additive optional-if-it-could-be, but here NON-optional-and-defaulted*
    /// field (like `normalizedText` above, not like `ocrText`/`pinnedAt`,
    /// because — unlike those — it's read inside a `#Predicate` scan, which
    /// requires a concrete default for SwiftData's lightweight migration to
    /// backfill onto every row that predates this field, per this file's own
    /// established precedent; see `normalizedText`'s doc comment for the full
    /// mechanics/crash history of that requirement). Existing on-disk rows
    /// (every row captured before this fix ships) migrate in as `false` —
    /// correctly, since their `contentHash` is still whatever the OLD
    /// raw-byte hash algorithm produced.
    ///
    /// Purely an internal storage/migration-bookkeeping flag: never read by
    /// `asClipItem()`, never part of the domain `ClipItem` struct, and no
    /// other code in this file depends on it being accurate for a row's OWN
    /// correctness (a row's `contentHash` is either already-correct or
    /// pending correction regardless of this flag's value) — only for
    /// whether the backfill still needs to *visit* that row.
    var pixelContentHashMigrated: Bool = false

    init(
      id: UUID,
      createdAt: Date,
      kindRawValue: String,
      previewText: String,
      normalizedText: String,
      contentHash: String,
      pinned: Bool,
      pinnedAt: Date?,
      sourceAppName: String?,
      sourceBundleID: String?,
      byteSize: Int,
      blobPath: String?,
      fileReference: String?,
      ocrText: String? = nil,
      pixelContentHashMigrated: Bool = false
    ) {
      self.id = id
      self.createdAt = createdAt
      self.kindRawValue = kindRawValue
      self.previewText = previewText
      self.normalizedText = normalizedText
      self.contentHash = contentHash
      self.pinned = pinned
      self.pinnedAt = pinnedAt
      self.sourceAppName = sourceAppName
      self.sourceBundleID = sourceBundleID
      self.byteSize = byteSize
      self.blobPath = blobPath
      self.fileReference = fileReference
      self.ocrText = ocrText
      self.pixelContentHashMigrated = pixelContentHashMigrated
    }

    /// `pixelContentHashMigrated: true` — a freshly-inserted row (the only
    /// caller of this convenience init is `insertOrBumpDuplicate`) carries a
    /// `contentHash` already computed via the current decoded-pixel algorithm
    /// by the caller (see `pixelContentHashMigrated`'s doc comment), so it
    /// never needs to be revisited by the backfill. Test code that needs to
    /// simulate a genuinely LEGACY row (predates this fix, still carries the
    /// OLD raw-byte hash) must bypass this convenience init — see
    /// `SwiftDataClipStore.insertRecordNeedingImageContentHashBackfillForTesting(_:in:)`.
    convenience init(_ item: ClipItem) {
      self.init(
        id: item.id,
        createdAt: item.createdAt,
        kindRawValue: item.kind.rawValue,
        previewText: item.previewText,
        normalizedText: Self.computeNormalizedText(
          previewText: item.previewText, ocrText: item.ocrText),
        contentHash: item.contentHash,
        pinned: item.pinned,
        pinnedAt: item.pinnedAt,
        sourceAppName: item.sourceAppName,
        sourceBundleID: item.sourceBundleID,
        byteSize: item.byteSize,
        blobPath: item.blobPath,
        fileReference: item.fileReference,
        ocrText: item.ocrText,
        pixelContentHashMigrated: true
      )
    }

    /// The single derivation rule for `normalizedText` — `previewText` plus,
    /// once recognized, `ocrText` (so a screenshot becomes findable by its
    /// recognized contents too), lowercased. Every call site that computes
    /// `normalizedText` (`init(_ item:)`, the migration-crash-fix backfill,
    /// and `SwiftDataClipStore.setRecognizedText(_:text:)`) goes through this
    /// one function instead of re-inlining `.lowercased()` — coding-
    /// standards.md's DRY rule: this derivation existed in exactly one place
    /// before OCR, and stays that way now that a second field feeds it.
    ///
    /// One-line forwarder to `ClipItemNormalization.computeNormalizedText(previewText:ocrText:)`
    /// (`ClipItemNormalization.swift`) — the actual derivation lives there now,
    /// as a platform-neutral, SwiftData-free function the Linux port's future
    /// SQLite-backed `ClipStore` can reuse directly. Kept here too so this
    /// record's own call sites (listed above) need no changes.
    static func computeNormalizedText(previewText: String, ocrText: String?) -> String {
      ClipItemNormalization.computeNormalizedText(previewText: previewText, ocrText: ocrText)
    }

    /// Maps back to the domain struct. Falls back to `.text` on an
    /// unrecognized `kindRawValue` (e.g. a future downgrade reading a newer
    /// case) rather than crashing — `ItemKind(rawValue:)` is the only failable
    /// step in an otherwise total mapping. `normalizedText` is internal to
    /// this record (a derived index field, not part of the domain model) so
    /// it never threads through to `ClipItem`.
    func asClipItem() -> ClipItem {
      ClipItem(
        id: id,
        createdAt: createdAt,
        kind: ItemKind(rawValue: kindRawValue) ?? .text,
        previewText: previewText,
        contentHash: contentHash,
        pinned: pinned,
        pinnedAt: pinnedAt,
        sourceAppName: sourceAppName,
        sourceBundleID: sourceBundleID,
        byteSize: byteSize,
        blobPath: blobPath,
        fileReference: fileReference,
        ocrText: ocrText
      )
    }
  }
#endif
