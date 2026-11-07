import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

/// Pasteboard fake whose `changeCount` can be frozen (write never observed).
private final class ScriptedPasteboard: PasteboardWriting, @unchecked Sendable {
  var movesOnWrite = true
  private(set) var writes: [String] = []
  private(set) var richWrites: [(rtf: Data, plain: String)] = []
  private(set) var changeCount = 100

  func writeString(_ string: String, forType type: ClipMediaType) { record("s:\(string)") }
  func writeData(_ data: Data, forType type: ClipMediaType) { record("d") }
  func writeRichText(rtf: Data, plain: String) {
    richWrites.append((rtf, plain))
    record("r:\(plain)")
  }
  func writeFileURL(_ url: URL) { record("f") }

  private func record(_ entry: String) {
    writes.append(entry)
    if movesOnWrite { changeCount += 1 }
  }
}

/// `FileManager` whose deletes always fail (post-commit blob cleanup fails).
private final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

/// `Thread.isMainThread` is unavailable directly in async contexts.
private func onMainThread() -> Bool { Thread.isMainThread }

/// Store wrapper recording which thread `updateContent` ran on and whether
/// the blob already existed (written before the store call).
private final class SpyStore: ClipStore, @unchecked Sendable {
  let base: InMemoryClipStore
  let blobStore: BlobStore
  private(set) var updateRanOnMain: Bool?
  private(set) var blobExistedAtUpdate: Bool?
  /// When set, `updateContent` throws it instead of writing.
  var updateError: Error?
  init(base: InMemoryClipStore, blobStore: BlobStore) {
    self.base = base
    self.blobStore = blobStore
  }
  func updateContent(_ id: UUID, with update: ClipContentUpdate) async throws
    -> ClipContentUpdateResult
  {
    updateRanOnMain = onMainThread()
    blobExistedAtUpdate = update.blobPath.map { blobStore.contains(blobPath: $0) }
    if let updateError { throw updateError }
    return try await base.updateContent(id, with: update)
  }
  func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
    try await base.insertOrBumpDuplicate(item)
  }
  func fetchAll() async throws -> [ClipItem] { try await base.fetchAll() }
  func fetchPinned() async throws -> [ClipItem] { try await base.fetchPinned() }
  func query(text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int)
    async throws -> [ClipItem]
  { try await base.query(text: text, kind: kind, scope: scope, offset: offset, limit: limit) }
  func setPinned(_ id: UUID, pinned: Bool) async throws {
    try await base.setPinned(id, pinned: pinned)
  }
  func setRecognizedText(_ id: UUID, text: String) async throws {
    try await base.setRecognizedText(id, text: text)
  }
  func delete(_ id: UUID) async throws { try await base.delete(id) }
  func fetchImagesNeedingRecognition() async throws -> [ClipItem] {
    try await base.fetchImagesNeedingRecognition()
  }
  func clearHistory() async throws { try await base.clearHistory() }
  func enforceRetention(cap: RetentionCap?) async throws {
    try await base.enforceRetention(cap: cap)
  }
}

@MainActor
private final class Harness {
  let directory: URL
  let blobStore: BlobStore
  let store: InMemoryClipStore
  let pasteboard = ScriptedPasteboard()
  let reader = PasteboardReader()
  var payload: PasteboardReader.RawPayload?
  var suppressed: [Int] = []

  init() {
    (directory, blobStore) = makeTempBlobStore()
    store = InMemoryClipStore(blobStore: blobStore)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func coordinator(
    store override: (any ClipStore)? = nil, timeout: Duration = .milliseconds(80)
  ) -> ItemEditCoordinator {
    ItemEditCoordinator(
      clipStore: override ?? store, blobStore: blobStore, pasteboard: pasteboard,
      pasteboardReader: reader,
      readClipboardPayload: { [unowned self] in self.payload },
      suppressOwnPasteboardWrite: { [unowned self] in self.suppressed.append($0) },
      writeConfirmationTimeout: timeout)
  }

  /// Inserts an item exactly as capture would classify `text`.
  func insertText(_ text: String, pinned: Bool = false, in target: (any ClipStore)? = nil)
    async throws -> ClipItem
  {
    let c = try #require(reader.classify(.plainText(text)))
    let item = ClipItem(
      createdAt: Date(timeIntervalSince1970: 1_000), kind: c.kind, previewText: c.previewText,
      contentHash: c.contentHash, pinned: pinned, byteSize: c.byteSize)
    return try await (target ?? store).insertOrBumpDuplicate(item)
  }

  func blobFiles() -> [String] {
    let dir = directory.appendingPathComponent("blobs")
    return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
  }
}

private let boldBlob = Data("{\\rtf1 \\b bold\\b0}".utf8)

@MainActor
@Suite("ItemEditCoordinator")
struct ItemEditCoordinatorTests {
  @Test func saveReplacesInPlaceWithoutNewEntry() async throws {
    let h = Harness()
    let item = try await h.insertText("old", pinned: true)
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "new", hasFormatting: false, richBlob: Data()))
    guard case .saved(let saved, _) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    let all = try await h.store.fetchAll()
    #expect(all.count == 1)
    #expect(saved.id == item.id)
    #expect(saved.createdAt == item.createdAt)
    #expect(saved.pinned)
    #expect(saved.previewText == "new")
  }

  @Test func plainEditWithBoldProducesRichTextItemWithBlob() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    guard case .saved(let saved, _) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(saved.kind == .richText)
    #expect(saved.blobPath == BlobStore.blobPath(for: boldBlob))
    #expect(h.blobStore.contains(blobPath: try #require(saved.blobPath)))
  }

  @Test func editedItemEqualsFreshCaptureOfSameContent() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    let text = "  edited text\n"
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: text, hasFormatting: false, richBlob: Data()))
    guard case .saved(let saved, _) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    let fresh = try #require(h.reader.classify(.plainText(text)))
    #expect(saved.contentHash == fresh.contentHash)
    #expect(saved.previewText == fresh.previewText)
    #expect(saved.byteSize == fresh.byteSize)
    #expect(saved.kind == fresh.kind)
  }

  @Test func clipboardHoldingEditedItemIsRewrittenAndSuppressed() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    h.payload = .plainText("old")
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    guard case .saved(_, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .written)
    #expect(h.pasteboard.writes == ["r:bold"])
    #expect(h.pasteboard.richWrites.first?.rtf == boldBlob)
    #expect(h.suppressed == [h.pasteboard.changeCount])
  }

  @Test func clipboardHoldingEditedRichItemIsDetectedAndRewrittenAsRichText() async throws {
    let h = Harness()
    let rich = PasteboardReader.RawPayload.richText(rtf: boldBlob, fallbackPlainText: "bold")
    let c = try #require(h.reader.classify(rich))
    let path = try h.blobStore.write(boldBlob)
    let item = try await h.store.insertOrBumpDuplicate(
      ClipItem(
        kind: c.kind, previewText: c.previewText, contentHash: c.contentHash,
        byteSize: c.byteSize, blobPath: path))
    h.payload = rich
    let newBlob = Data("{\\rtf1 \\i italic}".utf8)
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "italic", hasFormatting: true, richBlob: newBlob))
    guard case .saved(_, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .written)
    #expect(h.pasteboard.richWrites.first?.rtf == newBlob)
  }

  @Test func plainEditRewritesClipboardAsString() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    h.payload = .plainText("old")
    _ = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "new", hasFormatting: false, richBlob: Data()))
    #expect(h.pasteboard.writes == ["s:new"])
  }

  @Test func clipboardHoldingSomethingElseIsUntouched() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    h.payload = .plainText("other")
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "new", hasFormatting: false, richBlob: Data()))
    guard case .saved(_, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .notOnClipboard)
    #expect(h.pasteboard.writes.isEmpty)
    #expect(h.suppressed.isEmpty)
  }

  @Test func clipboardChangedMidEditIsUntouched() async throws {
    let h = Harness()
    let item = try await h.insertText("X")
    // The clipboard held the item when the editor opened, but the user copied
    // Y during the edit: the payload read at save time is Y.
    h.payload = .plainText("Y")
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "edited", hasFormatting: false, richBlob: Data()))
    guard case .saved(let saved, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .notOnClipboard)
    #expect(h.pasteboard.writes.isEmpty)
    #expect(saved.previewText == "edited")
  }

  @Test func unconfirmedClipboardWriteReportsWriteUnconfirmed() async throws {
    let h = Harness()
    h.pasteboard.movesOnWrite = false
    let item = try await h.insertText("old")
    h.payload = .plainText("old")
    let outcome = await h.coordinator(timeout: .milliseconds(30)).saveContent(
      of: item, output: EditorOutput(plainText: "new", hasFormatting: false, richBlob: Data()))
    guard case .saved(_, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .writeUnconfirmed)
    // Armed with the predicted post-write count so a late-landing write is
    // not re-captured (bumped/duplicated) by the monitor.
    #expect(h.suppressed == [100 + 1])
  }

  @Test func deletedItemYieldsItemNoLongerExistsAndWritesNothing() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    h.payload = .plainText("old")
    try await h.store.delete(item.id)
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    #expect(outcome == .itemNoLongerExists)
    #expect(h.blobFiles().isEmpty)
    #expect(try await h.store.fetchAll().isEmpty)
    #expect(h.pasteboard.writes.isEmpty)
  }

  @Test func storeFailureDeletesTheBlobThisCallCreated() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    let spy = SpyStore(base: h.store, blobStore: h.blobStore)
    spy.updateError = ClipStoreError.ioFailure(underlying: "disk full")
    let outcome = await h.coordinator(store: spy).saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    #expect(outcome == .failed(message: ItemEditStrings.saveFailed))
    #expect(spy.blobExistedAtUpdate == true)
    #expect(h.blobFiles().isEmpty)
  }

  @Test func storeFailureKeepsAPreExistingBlob() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    let existing = try h.blobStore.write(boldBlob)
    let spy = SpyStore(base: h.store, blobStore: h.blobStore)
    spy.updateError = ClipStoreError.ioFailure(underlying: "disk full")
    let outcome = await h.coordinator(store: spy).saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    #expect(outcome == .failed(message: ItemEditStrings.saveFailed))
    #expect(h.blobStore.contains(blobPath: existing))
  }

  @Test func cleanupFailureAfterCommitStillReportsSavedAndSyncsClipboard() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EditCleanupFail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobStore = BlobStore(baseDirectory: directory, fileManager: FailingRemoveFileManager())
    let store = InMemoryClipStore(blobStore: blobStore)
    let pasteboard = ScriptedPasteboard()
    let reader = PasteboardReader()
    // A rich item whose old blob becomes orphaned (and undeletable) on edit.
    let old = Data("{\\rtf1 \\i old\\i0}".utf8)
    let c = try #require(reader.classify(.plainText("old")))
    let oldPath = try blobStore.write(old)
    let item = try await store.insertOrBumpDuplicate(
      ClipItem(
        createdAt: Date(), kind: .richText, previewText: "old", contentHash: c.contentHash,
        byteSize: 3, blobPath: oldPath))
    let coordinator = ItemEditCoordinator(
      clipStore: store, blobStore: blobStore, pasteboard: pasteboard, pasteboardReader: reader,
      readClipboardPayload: { .plainText("old") }, suppressOwnPasteboardWrite: { _ in },
      writeConfirmationTimeout: .milliseconds(80))
    let outcome = await coordinator.saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    guard case .saved(_, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .written)
    #expect(pasteboard.writes == ["r:bold"])
  }

  @Test func collidingEditMergesAndReportsSurvivor() async throws {
    let h = Harness()
    let a = try await h.insertText("a")
    let b = try await h.insertText("b")
    let outcome = await h.coordinator().saveContent(
      of: a, output: EditorOutput(plainText: "b", hasFormatting: false, richBlob: Data()))
    guard case .saved(let saved, _) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    let all = try await h.store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == saved.id)
    #expect([a.id, b.id].contains(saved.id))
  }

  @Test func loadSourceForRichTextWithMissingBlobFallsBackToPlain() async throws {
    let h = Harness()
    let item = ClipItem(
      kind: .richText, previewText: "plain", contentHash: "h", blobPath: "blobs/missing")
    let source = await h.coordinator().loadSource(for: item)
    #expect(source.richBlob == nil)
    #expect(source.plainText == "plain")
    #expect(source.richContentMissing)
  }

  @Test func loadSourceForPlainTextItemIsNotMissingRichContent() async throws {
    let h = Harness()
    let item = try await h.insertText("plain")
    let source = await h.coordinator().loadSource(for: item)
    #expect(!source.richContentMissing)
  }

  @Test func emptyRichBlobIsRejectedAndWritesNothing() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "x", hasFormatting: true, richBlob: Data()))
    #expect(outcome == .failed(message: ItemEditStrings.saveFailed))
    #expect(h.blobFiles().isEmpty)
    let stored = try #require(try await h.store.fetchAll().first)
    #expect(stored.previewText == "old")
  }

  @Test func clipboardRewriteUsesTheTextTheHashWasComputedFrom() async throws {
    let h = Harness()
    let item = try await h.insertText("old")
    h.payload = .plainText("old")
    let outcome = await h.coordinator().saveContent(
      of: item, output: EditorOutput(plainText: "abc\n", hasFormatting: false, richBlob: Data()))
    guard case .saved(let saved, _) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(h.pasteboard.writes == ["s:abc\n"])
    let rehash = try #require(h.reader.classify(.plainText("abc\n")))
    #expect(rehash.contentHash == saved.contentHash)
  }

  @Test func loadSourceForImageReturnsRecognizedText() async throws {
    let h = Harness()
    let item = ClipItem(
      kind: .image, previewText: "Image 800\u{00D7}600", contentHash: "h", ocrText: "hello")
    let source = await h.coordinator().loadSource(for: item)
    #expect(source.plainText == "hello")
    #expect(source.richBlob == nil)
    #expect(!source.richContentMissing)
  }

  @Test func loadSourceForRichTextReadsBlob() async throws {
    let h = Harness()
    let path = try h.blobStore.write(boldBlob)
    let item = ClipItem(kind: .richText, previewText: "bold", contentHash: "h", blobPath: path)
    let source = await h.coordinator().loadSource(for: item)
    #expect(source.richBlob == boldBlob)
    #expect(!source.richContentMissing)
  }

  @Test func saveRecognizedTextChangesSearchAndLeavesImageBlob() async throws {
    let h = Harness()
    let path = try h.blobStore.write(Data([1, 2, 3]))
    let image = try await h.store.insertOrBumpDuplicate(
      ClipItem(
        kind: .image, previewText: "img", contentHash: "imgh", blobPath: path, ocrText: "old ocr"))
    let outcome = await h.coordinator().saveRecognizedText(of: image, text: "zebra words")
    guard case .saved(let saved, let sync) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(sync == .notOnClipboard)
    #expect(saved.blobPath == path)
    let found = try await h.store.query(
      text: "zebra", kind: nil, scope: .history, offset: 0, limit: 10)
    #expect(found.map(\.id) == [image.id])
    #expect(h.blobStore.contains(blobPath: path))
    #expect(h.pasteboard.writes.isEmpty)
  }

  @Test func saveRecognizedTextForDeletedItem() async throws {
    let h = Harness()
    let ghost = ClipItem(kind: .image, previewText: "i", contentHash: "g", ocrText: "x")
    #expect(await h.coordinator().saveRecognizedText(of: ghost, text: "y") == .itemNoLongerExists)
  }

  @Test func hashingAndBlobWriteRunOffMainActor() async throws {
    let h = Harness()
    let spy = SpyStore(base: h.store, blobStore: h.blobStore)
    let item = try await h.insertText("old")
    _ = await h.coordinator(store: spy).saveContent(
      of: item, output: EditorOutput(plainText: "bold", hasFormatting: true, richBlob: boldBlob))
    #expect(spy.updateRanOnMain == false)
    // The blob is already on disk when the store is called (written in the
    // detached task, before the store update).
    #expect(spy.blobExistedAtUpdate == true)
  }
}
