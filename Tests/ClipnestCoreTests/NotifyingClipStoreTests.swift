import Foundation
import Testing

@testable import ClipnestCore

/// T-RT2: proves `NotifyingClipStore` broadcasts the right `ClipStoreChange`
/// for every mutating `ClipStore` method, broadcasts NOTHING for read-only
/// methods or a failed mutation, and otherwise behaves exactly like the
/// store it wraps (every call/result/error passes straight through).
/// Wraps `InMemoryClipStore` — the wrapper is store-implementation-agnostic
/// by construction (it only ever calls through the `ClipStore` protocol),
/// so this one conformance is sufficient to prove the decorator's own
/// behavior; `SwiftDataClipStore`/`SQLiteClipStore` get this for free
/// without needing their own copy of these scenarios.
@Suite("NotifyingClipStore")
struct NotifyingClipStoreTests {

  private func makeSUT() -> (store: NotifyingClipStore, blobStore: BlobStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NotifyingClipStoreTests-\(UUID().uuidString)", isDirectory: true)
    let blobStore = BlobStore(baseDirectory: directory)
    let store = NotifyingClipStore(wrapping: InMemoryClipStore(blobStore: blobStore))
    return (store, blobStore, directory)
  }

  private func recordChanges(from store: NotifyingClipStore) -> (
    changes: RecordedChanges, subscription: ClipStoreChangeSubscription
  ) {
    let recorded = RecordedChanges()
    let subscription = store.changes.subscribe { change in
      recorded.append(change)
    }
    return (recorded, subscription)
  }

  @Test("insertOrBumpDuplicate broadcasts .inserted with the resulting stored item")
  func insertBroadcastsInserted() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    let item = ClipStoreContractTests.makeItem(contentHash: "hash-1")
    let stored = try await store.insertOrBumpDuplicate(item)

    #expect(recorded.all == [.inserted(stored)])
  }

  @Test("setPinned broadcasts .updated(id)")
  func setPinnedBroadcastsUpdated() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    let item = ClipStoreContractTests.makeItem(contentHash: "hash-2")
    let stored = try await store.insertOrBumpDuplicate(item)
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    try await store.setPinned(stored.id, pinned: true)

    #expect(recorded.all == [.updated(stored.id)])
  }

  @Test("setRecognizedText broadcasts .updated(id)")
  func setRecognizedTextBroadcastsUpdated() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    let item = ClipStoreContractTests.makeItem(contentHash: "hash-3", kind: .image)
    let stored = try await store.insertOrBumpDuplicate(item)
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    try await store.setRecognizedText(stored.id, text: "hello")

    #expect(recorded.all == [.updated(stored.id)])
  }

  @Test("delete broadcasts .deleted(id)")
  func deleteBroadcastsDeleted() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    let item = ClipStoreContractTests.makeItem(contentHash: "hash-4")
    let stored = try await store.insertOrBumpDuplicate(item)
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    try await store.delete(stored.id)

    #expect(recorded.all == [.deleted(stored.id)])
  }

  @Test("delete on a missing id propagates .notFound and broadcasts nothing")
  func deleteOfMissingIDBroadcastsNothing() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    await #expect(throws: ClipStoreError.notFound) {
      try await store.delete(UUID())
    }

    #expect(recorded.all.isEmpty)
  }

  @Test("clearHistory broadcasts .clearedAll")
  func clearHistoryBroadcastsClearedAll() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "hash-5"))
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    try await store.clearHistory()

    #expect(recorded.all == [.clearedAll])
  }

  @Test("enforceRetention(cap: nil) is a documented no-op and broadcasts nothing")
  func enforceRetentionWithNoCapBroadcastsNothing() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    try await store.enforceRetention(cap: nil)

    #expect(recorded.all.isEmpty)
  }

  @Test("enforceRetention with a real cap broadcasts .retentionApplied")
  func enforceRetentionWithCapBroadcastsRetentionApplied() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "hash-6"))
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    try await store.enforceRetention(cap: .maxCount(0))

    #expect(recorded.all == [.retentionApplied])
  }

  @Test(
    "Read-only methods (fetchAll, fetchPinned, query, fetchImagesNeedingRecognition) broadcast nothing"
  )
  func readOnlyMethodsBroadcastNothing() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.insertOrBumpDuplicate(
      ClipStoreContractTests.makeItem(contentHash: "hash-7"))
    let (recorded, subscription) = recordChanges(from: store)
    defer { subscription.cancel() }

    _ = try await store.fetchAll()
    _ = try await store.fetchPinned()
    _ = try await store.query(text: "", kind: nil, scope: .history, offset: 0, limit: 10)
    _ = try await store.fetchImagesNeedingRecognition()

    #expect(recorded.all.isEmpty)
  }

  @Test("Every read/write result passes straight through to the wrapped store")
  func passesThroughToWrappedStore() async throws {
    let (store, _, directory) = makeSUT()
    defer { try? FileManager.default.removeItem(at: directory) }

    let item = ClipStoreContractTests.makeItem(contentHash: "hash-8", previewText: "hello world")
    let stored = try await store.insertOrBumpDuplicate(item)
    let fetched = try await store.fetchAll()

    #expect(fetched == [stored])
    #expect(stored.previewText == "hello world")
  }
}

/// Thread-confined (this suite calls `send(_:)` synchronously from a single
/// `async` test body, never concurrently) accumulator for
/// `ClipStoreChangeBroadcaster.subscribe(_:)`'s `@Sendable` handler.
private final class RecordedChanges: @unchecked Sendable {
  private(set) var all: [ClipStoreChange] = []
  func append(_ change: ClipStoreChange) { all.append(change) }
}
