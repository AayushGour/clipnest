import Foundation
import SwiftData
import Testing

@testable import ClipnestCore

/// Direct unit tests for the shared `OneShotStoreMigration.run(...)` helper
/// (`Sources/ClipnestCore/Store/OneShotStoreMigration.swift`), extracted out
/// of `SwiftDataClipStore`/`SwiftDataSnippetStore`'s near-identical
/// completion-marker plumbing (T-PF1 review, DRY finding). These tests drive
/// `run(...)` directly with a controllable `migration` closure rather than
/// going through a real `normalizedText` backfill — that's the only way to
/// deterministically exercise the failure path (a genuine SwiftData
/// fetch/save failure isn't reliably injectable against a real store), and
/// it isolates this helper's own correctness from either store's specific
/// backfill logic.
///
/// The completion marker itself is exercised against `FakeOneShotMigrationStorage`
/// (an in-memory `OneShotMigrationStorage`), never a real `UserDefaults`
/// suite — a real `UserDefaults(suiteName:)` write is asynchronously
/// flushed to disk by `cfprefsd`, which raced with attempts to clean up the
/// suite's backing `.plist` immediately after a test and intermittently
/// left stray files behind in the real, user-visible
/// `~/Library/Preferences` (observed empirically while first writing this
/// suite). Every test uses its own fresh fake + its own temp-directory
/// store file, so this suite needs no `.serialized` trait — nothing here is
/// shared mutable state across tests, unlike the two Store test suites (see
/// their doc comments).
@Suite("OneShotStoreMigration")
struct OneShotStoreMigrationTests {

  private static let testKeyPrefix = "ClipnestCoreTests.OneShotStoreMigrationTests.marker."

  /// A real on-disk (not `isStoredInMemoryOnly`) context at `url` — required
  /// to exercise the marker-persistence path (`run(...)` never persists a
  /// marker for an in-memory container; see `inMemoryContainerNeverPersistsMarker`
  /// below for that case specifically).
  private func makeOnDiskContext(url: URL) throws -> ModelContext {
    let schema = Schema([OneShotStoreMigrationTestRecord.self])
    let configuration = ModelConfiguration(schema: schema, url: url)
    let container = try ModelContainer(for: schema, configurations: configuration)
    return ModelContext(container)
  }

  private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([OneShotStoreMigrationTestRecord.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: configuration)
    return ModelContext(container)
  }

  private func makeTempStoreURL(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "OneShotStoreMigrationTests-\(label)-\(UUID().uuidString).store")
  }

  // MARK: - Failure path (the reviewer-finding correctness fix)

  @Test(
    "A migration that fails (returns false) does not set the completion marker, so the next run() call for the same store file retries it"
  )
  func failedMigrationDoesNotMarkCompleteAndRetries() throws {
    let fileURL = makeTempStoreURL("fail")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let context = try makeOnDiskContext(url: fileURL)
    let storage = FakeOneShotMigrationStorage()
    let expectedKey = Self.testKeyPrefix + fileURL.path

    var runCount = 0
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return false  // simulated transient failure (e.g. a fetch/save error)
    }
    #expect(runCount == 1)
    #expect(!storage.bool(forKey: expectedKey))

    // A later prepare() call against the SAME store file (simulating the
    // next launch): since the marker was never set, migration() must run
    // again rather than being silently skipped forever.
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return true  // this time it succeeds
    }
    #expect(runCount == 2)
    #expect(storage.bool(forKey: expectedKey))

    // Now that it has genuinely succeeded once, a THIRD call must not run
    // migration() again.
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return true
    }
    #expect(runCount == 2)
  }

  @Test(
    "A migration that succeeds sets the completion marker, so a subsequent run() call for the same store file does not re-run it"
  )
  func successfulMigrationMarksCompleteAndSkipsNextRun() throws {
    let fileURL = makeTempStoreURL("success")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let context = try makeOnDiskContext(url: fileURL)
    let storage = FakeOneShotMigrationStorage()

    var runCount = 0
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return true
    }
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return true
    }

    #expect(runCount == 1)
    #expect(storage.bool(forKey: Self.testKeyPrefix + fileURL.path))
  }

  // MARK: - Per-store-path isolation

  @Test(
    "The completion marker is isolated per on-disk store file: completing the migration for one file does not skip it for a different file"
  )
  func markerIsIsolatedPerStoreFilePath() throws {
    let firstURL = makeTempStoreURL("isolation-first")
    let secondURL = makeTempStoreURL("isolation-second")
    defer {
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
    }
    let firstContext = try makeOnDiskContext(url: firstURL)
    let secondContext = try makeOnDiskContext(url: secondURL)
    let storage = FakeOneShotMigrationStorage()

    var firstRunCount = 0
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: firstContext, storage: storage
    ) {
      firstRunCount += 1
      return true
    }
    #expect(firstRunCount == 1)

    // Completing the FIRST file's migration must not skip the SECOND file's
    // — each on-disk store file earns its own "already done" fact
    // independently, even though both calls share the same `keyPrefix`.
    var secondRunCount = 0
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: secondContext, storage: storage
    ) {
      secondRunCount += 1
      return true
    }
    #expect(secondRunCount == 1)

    // And each file's own marker still independently prevents ITS re-run.
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: firstContext, storage: storage
    ) {
      firstRunCount += 1
      return true
    }
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: secondContext, storage: storage
    ) {
      secondRunCount += 1
      return true
    }
    #expect(firstRunCount == 1)
    #expect(secondRunCount == 1)
  }

  @Test(
    "Two different keyPrefixes against the SAME store file are gated independently — proves a second one-shot migration (e.g. a future contentHash backfill) can share a store file without colliding with an existing marker"
  )
  func differentKeyPrefixesOnSameFileAreIndependent() throws {
    let fileURL = makeTempStoreURL("multi-migration")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let context = try makeOnDiskContext(url: fileURL)
    let storage = FakeOneShotMigrationStorage()
    let firstPrefix = "ClipnestCoreTests.OneShotStoreMigrationTests.migrationA."
    let secondPrefix = "ClipnestCoreTests.OneShotStoreMigrationTests.migrationB."

    var firstMigrationRunCount = 0
    OneShotStoreMigration.run(
      keyPrefix: firstPrefix, modelContext: context, storage: storage
    ) {
      firstMigrationRunCount += 1
      return true
    }
    var secondMigrationRunCount = 0
    OneShotStoreMigration.run(
      keyPrefix: secondPrefix, modelContext: context, storage: storage
    ) {
      secondMigrationRunCount += 1
      return true
    }
    #expect(firstMigrationRunCount == 1)
    #expect(secondMigrationRunCount == 1)

    // Re-running each prefix against the same file must not run the OTHER
    // prefix's migration, nor re-run its own — each keyPrefix has its own
    // independent completion marker for this one file.
    OneShotStoreMigration.run(
      keyPrefix: firstPrefix, modelContext: context, storage: storage
    ) {
      firstMigrationRunCount += 1
      return true
    }
    OneShotStoreMigration.run(
      keyPrefix: secondPrefix, modelContext: context, storage: storage
    ) {
      secondMigrationRunCount += 1
      return true
    }
    #expect(firstMigrationRunCount == 1)
    #expect(secondMigrationRunCount == 1)
  }

  // MARK: - In-memory containers

  @Test(
    "An in-memory container never persists a completion marker, so migration() runs on every call"
  )
  func inMemoryContainerNeverPersistsMarker() throws {
    let context = try makeInMemoryContext()
    let storage = FakeOneShotMigrationStorage()

    var runCount = 0
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return true
    }
    OneShotStoreMigration.run(
      keyPrefix: Self.testKeyPrefix, modelContext: context, storage: storage
    ) {
      runCount += 1
      return true
    }

    #expect(runCount == 2)
  }
}

// MARK: - FakeOneShotMigrationStorage (in-memory OneShotMigrationStorage)

/// An in-memory `OneShotMigrationStorage` double — see `OneShotMigrationStorage`'s
/// doc comment (`OneShotStoreMigration.swift`) for why this replaces a real
/// `UserDefaults` suite in these tests. `@unchecked Sendable` mirrors this
/// codebase's existing test-double convention (e.g. `FakePasteboardWriting`
/// in `PasterTests.swift`) — each instance is freshly created per test and
/// never shared across concurrent tests.
private final class FakeOneShotMigrationStorage: OneShotMigrationStorage, @unchecked Sendable {
  private var values: [String: Bool] = [:]

  func bool(forKey key: String) -> Bool {
    values[key] ?? false
  }

  func set(_ value: Bool, forKey key: String) {
    values[key] = value
  }
}

// MARK: - OneShotStoreMigrationTestRecord (test-local minimal @Model)

/// A minimal `@Model` entity used only to construct real `ModelContainer`s
/// (on-disk and in-memory) for `OneShotStoreMigrationTests` — `run(...)`
/// itself is entirely agnostic to what's stored; this exists only because
/// `ModelContainer`/`ModelContext` require at least one registered `@Model`
/// type. Named uniquely (not `ClipItemRecord`/`SnippetRecord`) so it can
/// never collide with either production store's own private entity, or with
/// the test-local pre-migration-fix stand-ins declared in
/// `SwiftDataClipStoreTests.swift`/`SwiftDataSnippetStoreTests.swift`.
@Model
private final class OneShotStoreMigrationTestRecord {
  @Attribute(.unique) var id: UUID

  init(id: UUID = UUID()) {
    self.id = id
  }
}
