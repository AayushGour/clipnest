import Foundation
import SwiftData
import os

/// SwiftData-backed `SnippetStore` — the production persistence layer (plan
/// task T40, project-context.md decision D6). Mirrors `SwiftDataClipStore`'s
/// shape exactly (private `@Model` entity + domain-struct mapping, plain
/// `actor` rather than `@ModelActor` — see that type's doc comment for why).
public actor SwiftDataSnippetStore: SnippetStore {
  private let modelContext: ModelContext

  /// - Parameter modelContainer: Where records are persisted. Production
  ///   code uses `SwiftDataSnippetStore.makeProductionContainer()`; tests
  ///   must pass a container configured `isStoredInMemoryOnly: true` (or
  ///   pointed at a throwaway temp directory) — never the real container.
  public init(modelContainer: ModelContainer) {
    let modelContext = ModelContext(modelContainer)
    // Migration-crash fix: repair rows that migrated in with `normalizedText`
    // defaulted to `""` — see `SwiftDataClipStore.init`'s identical backfill
    // call and `SnippetRecord.normalizedText`'s doc comment for the full
    // rationale, which applies identically here.
    Self.backfillNormalizedText(in: modelContext)
    self.modelContext = modelContext
  }

  // MARK: - Production container

  private static let storeFileName = "Snippets.store"

  /// The production on-disk container: `~/Library/Application
  /// Support/Clipnest/Snippets.store` — the same base-directory family as
  /// `BlobStore.defaultBaseDirectory()` and `SwiftDataClipStore`. Never
  /// called by tests.
  public static func makeProductionContainer() throws -> ModelContainer {
    let baseDirectory = BlobStore.defaultBaseDirectory()
    do {
      try FileManager.default.createDirectory(
        at: baseDirectory, withIntermediateDirectories: true)
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
    let storeURL = baseDirectory.appendingPathComponent(storeFileName)
    let configuration = ModelConfiguration(url: storeURL)
    do {
      return try ModelContainer(for: SnippetRecord.self, configurations: configuration)
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// An `isStoredInMemoryOnly` container for tests — never touches disk;
  /// see `SwiftDataClipStore.makeTestContainer()`'s doc comment for the
  /// full rationale, which applies identically here.
  public static func makeTestContainer() throws -> ModelContainer {
    // In-memory test store (leaves nothing on disk); the explicit `Schema`
    // keeps SwiftData from inferring the model via `Bundle.main`. See
    // SwiftDataClipStore.makeTestContainer() for the full rationale.
    let schema = Schema([SnippetRecord.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    do {
      return try ModelContainer(for: schema, configurations: configuration)
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// Test-only: an on-disk (not `isStoredInMemoryOnly`) container at an
  /// explicit `url` — see `SwiftDataClipStore.makeContainerForTesting(at:)`'s
  /// doc comment for the full rationale, which applies identically here.
  public static func makeContainerForTesting(at url: URL) throws -> ModelContainer {
    // Explicit Schema so SwiftData maps the model directly rather than
    // inferring it via `Bundle.main`. See makeTestContainer().
    let schema = Schema([SnippetRecord.self])
    let configuration = ModelConfiguration(schema: schema, url: url)
    do {
      return try ModelContainer(for: schema, configurations: configuration)
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  /// Test-only: inserts `snippet` directly into `container` with an
  /// **empty** `normalizedText`, bypassing the normal `title + " " + body`
  /// computation — simulates a row exactly as it looks the moment it
  /// migrates in from a pre-`normalizedText` on-disk store (see
  /// `SnippetRecord.normalizedText`'s doc comment), so tests can prove
  /// `init`'s backfill repairs it. `SnippetRecord` is `private` to this
  /// file, so this factory is the only way test code can construct one
  /// directly. Never called by production code.
  public static func insertRecordWithEmptyNormalizedTextForTesting(
    _ snippet: Snippet, in container: ModelContainer
  ) throws {
    let context = ModelContext(container)
    let record = SnippetRecord(snippet)
    record.normalizedText = ""
    context.insert(record)
    do {
      try context.save()
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  // MARK: - Migration-crash fix: normalizedText backfill

  private static let logger = Logger(
    subsystem: "com.clipnest.app", category: "SwiftDataSnippetStore")

  /// One-time backfill for rows that migrated in with `normalizedText`
  /// defaulted to `""` — see `SwiftDataClipStore.backfillNormalizedText(in:)`'s
  /// doc comment for the full rationale (default-value migration mechanics,
  /// why this is safe to run unconditionally on every `init`, and why
  /// failures here are logged + swallowed rather than thrown), which applies
  /// identically here. Matches `update(_:title:body:keyword:)`'s derivation
  /// exactly: `(title + " " + body).lowercased()`.
  private static func backfillNormalizedText(in modelContext: ModelContext) {
    let predicate = #Predicate<SnippetRecord> { record in
      record.normalizedText == "" && (record.title != "" || record.body != "")
    }
    let descriptor = FetchDescriptor<SnippetRecord>(predicate: predicate)
    let staleRecords: [SnippetRecord]
    do {
      staleRecords = try modelContext.fetch(descriptor)
    } catch {
      logger.error(
        "SwiftDataSnippetStore: normalizedText backfill fetch failed (\(String(describing: error), privacy: .public))"
      )
      return
    }
    guard !staleRecords.isEmpty else { return }

    for record in staleRecords {
      record.normalizedText = (record.title + " " + record.body).lowercased()
    }
    do {
      try modelContext.save()
    } catch {
      logger.error(
        "SwiftDataSnippetStore: normalizedText backfill save failed (\(String(describing: error), privacy: .public))"
      )
    }
  }

  // MARK: - SnippetStore

  public func create(_ snippet: Snippet) async throws -> Snippet {
    let record = SnippetRecord(snippet)
    modelContext.insert(record)
    try save()
    return record.asSnippet()
  }

  public func update(
    _ id: UUID,
    title: String,
    body: String,
    keyword: String?
  ) async throws -> Snippet {
    guard let record = try fetchRecord(id: id) else { throw SnippetStoreError.notFound }
    record.title = title
    record.body = body
    record.keyword = keyword
    record.normalizedText = (title + " " + body).lowercased()
    try save()
    return record.asSnippet()
  }

  public func delete(_ id: UUID) async throws {
    guard let record = try fetchRecord(id: id) else { throw SnippetStoreError.notFound }
    modelContext.delete(record)
    try save()
  }

  public func fetchAll() async throws -> [Snippet] {
    var descriptor = FetchDescriptor<SnippetRecord>()
    descriptor.sortBy = [SortDescriptor(\SnippetRecord.createdAt, order: .reverse)]
    return try fetch(descriptor: descriptor).map { $0.asSnippet() }
  }

  public func query(text: String, offset: Int, limit: Int) async throws -> [Snippet] {
    let lowercasedText = text.lowercased()
    let hasText = !lowercasedText.isEmpty
    let predicate = #Predicate<SnippetRecord> { record in
      !hasText || record.normalizedText.contains(lowercasedText)
    }
    var descriptor = FetchDescriptor<SnippetRecord>(predicate: predicate)
    descriptor.sortBy = [SortDescriptor(\SnippetRecord.createdAt, order: .reverse)]
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit
    return try fetch(descriptor: descriptor).map { $0.asSnippet() }
  }

  public func findByKeyword(_ keyword: String) async throws -> Snippet? {
    let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return nil }
    // Fetch only keyworded records, newest-first, then match in Swift — the
    // trim + case-fold on an optional field isn't expressible in a
    // `#Predicate`, and adding a stored `normalizedKeyword` would be a schema
    // change (migration). Snippet counts are small (user-authored), so
    // fetching all keyworded rows is cheap.
    let predicate = #Predicate<SnippetRecord> { $0.keyword != nil }
    var descriptor = FetchDescriptor<SnippetRecord>(predicate: predicate)
    descriptor.sortBy = [SortDescriptor(\SnippetRecord.createdAt, order: .reverse)]
    let records = try fetch(descriptor: descriptor)
    let match = records.first { record in
      guard
        let candidate = record.keyword?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      else { return false }
      return candidate == needle
    }
    return match?.asSnippet()
  }

  // MARK: - Fetch/save helpers

  private func fetchRecord(id: UUID) throws -> SnippetRecord? {
    let predicate = #Predicate<SnippetRecord> { $0.id == id }
    var descriptor = FetchDescriptor<SnippetRecord>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try fetch(descriptor: descriptor).first
  }

  private func fetch(descriptor: FetchDescriptor<SnippetRecord>) throws -> [SnippetRecord] {
    do {
      return try modelContext.fetch(descriptor)
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }

  private func save() throws {
    do {
      try modelContext.save()
    } catch {
      throw SnippetStoreError.ioFailure(underlying: String(describing: error))
    }
  }
}

// MARK: - SnippetRecord (private @Model entity)

/// The private SwiftData entity backing `SwiftDataSnippetStore`. Mirrors
/// every field of `Snippet` — never referenced outside this file, and never
/// returned from any `SnippetStore` method; see `ClipItemRecord`'s doc
/// comment (`SwiftDataClipStore.swift`) for the full rationale, which
/// applies identically here.
@Model
private final class SnippetRecord {
  @Attribute(.unique) var id: UUID
  var title: String
  var body: String
  var keyword: String?
  var createdAt: Date
  /// `(title + " " + body).lowercased()`, kept in sync on insert (both
  /// initializers) and update (`SwiftDataSnippetStore.update(_:title:body:keyword:)`)
  /// — powers `query(text:offset:limit:)`'s case-insensitive title-OR-body
  /// match inside a `#Predicate`. `#Index`/`#Unique` on this field were
  /// considered but skipped: those macros require macOS 15+, and this
  /// project's deployment target is macOS 14 (coding-standards.md); the
  /// `fetchLimit`/`fetchOffset` on the query's `FetchDescriptor` bound query
  /// cost regardless.
  ///
  /// Migration-crash fix: the `= ""` default is required, not decorative —
  /// see `ClipItemRecord.normalizedText`'s doc comment
  /// (`SwiftDataClipStore.swift`) for the full rationale (SwiftData
  /// lightweight migration needs a new non-optional attribute to be
  /// defaulted, or it can't migrate an existing on-disk store in-place),
  /// which applies identically here. `SwiftDataSnippetStore.init`'s
  /// one-time backfill (`backfillNormalizedText(in:)`) then repairs any row
  /// that migrated in with this default.
  var normalizedText: String = ""

  init(id: UUID, title: String, body: String, keyword: String?, createdAt: Date) {
    self.id = id
    self.title = title
    self.body = body
    self.keyword = keyword
    self.createdAt = createdAt
    self.normalizedText = (title + " " + body).lowercased()
  }

  convenience init(_ snippet: Snippet) {
    self.init(
      id: snippet.id,
      title: snippet.title,
      body: snippet.body,
      keyword: snippet.keyword,
      createdAt: snippet.createdAt
    )
  }

  func asSnippet() -> Snippet {
    Snippet(id: id, title: title, body: body, keyword: keyword, createdAt: createdAt)
  }
}
