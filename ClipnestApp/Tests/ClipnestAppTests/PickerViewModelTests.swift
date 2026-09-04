// PickerViewModelTests.swift
//
// Covers `PickerViewModel`'s PURE decision logic — the architecture and
// implementation reviews specifically flagged `pasteContent(for:plainText:)`
// (plain vs. formatted paste) as untested. `pasteContent` and
// `resolvedSelection` were `private` (unreachable via `@testable import`,
// which only elevates `internal` symbols) and are now `internal` — see
// their doc comments in `PickerViewModel.swift` for why that's the one
// trivial, clearly-safe visibility change this task made. Every other
// symbol used here (`rows`, `isSearching`, `activeTab`, `SelectionPolicy`,
// `select(_:plainText:)`) was already `internal`/`private(set)` and needed
// no change.
//
// Deliberately NOT tested here (per this task's scope): SwiftUI rendering,
// real pasteboard writes, hotkey registration, and the synthesized-⌘V paste
// path itself (`select`'s `pasteAndDismiss` → `Paster.paste`) — covered by
// `Tests/ClipnestCoreTests/PasterTests.swift` already, with the real
// `CGEvent`/`NSPasteboard` boundary mocked there. `select(_:plainText:)` is
// exercised below ONLY up through its pure `pasteContent` decision (the
// synchronous part); its subsequent `Task { ... paster.paste(...) }` is
// intentionally left alone.

import ClipnestCore
import Foundation
import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import Clipnest

// MARK: - pasteContent(for:plainText:)

@MainActor
@Suite("PickerViewModel.pasteContent")
struct PickerViewModelPasteContentTests {

  @Test(".text pastes its previewText verbatim")
  func textPastesPreviewText() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .text, previewText: "hello world")

    #expect(await viewModel.pasteContent(for: item, plainText: false) == .text("hello world"))
  }

  @Test(".text ignores plainText — there's no richer form to strip")
  func textIgnoresPlainTextFlag() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .text, previewText: "hello world")

    #expect(await viewModel.pasteContent(for: item, plainText: true) == .text("hello world"))
  }

  @Test(".link pastes its previewText verbatim")
  func linkPastesPreviewText() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .link, previewText: "https://example.com")

    #expect(
      await viewModel.pasteContent(for: item, plainText: false) == .text("https://example.com"))
  }

  @Test(".link ignores plainText — there's no richer form to strip")
  func linkIgnoresPlainTextFlag() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .link, previewText: "https://example.com")

    #expect(
      await viewModel.pasteContent(for: item, plainText: true) == .text("https://example.com"))
  }

  @Test(".richText with a stored RTF blob pastes the rich form (RTF bytes + plain fallback)")
  func richTextWithBlobPastesRich() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rtfBytes = Data("{\\rtf1\\ansi bold}".utf8)
    let blobPath = try blobStore.write(rtfBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .richText, previewText: "bold", blobPath: blobPath)

    let result = await viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .richText(rtf: rtfBytes, plain: "bold"))
  }

  @Test(
    "`plainText: true` strips .richText to its plain previewText, even though a valid RTF blob is stored"
  )
  func richTextWithBlobPlainTextStripsToPlain() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rtfBytes = Data("{\\rtf1\\ansi bold}".utf8)
    let blobPath = try blobStore.write(rtfBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .richText, previewText: "bold", blobPath: blobPath)

    let result = await viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .text("bold"))
  }

  @Test("A legacy .richText item with no stored blob falls back to its plain previewText")
  func richTextWithoutBlobFallsBackToPlain() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .richText, previewText: "legacy plain", blobPath: nil)

    let result = await viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .text("legacy plain"))
  }

  @Test("A .richText item whose blob is missing on disk falls back to its plain previewText")
  func richTextWithMissingBlobFallsBackToPlain() async {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .richText, previewText: "orphaned", blobPath: "blobs/does-not-exist")

    let result = await viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .text("orphaned"))
  }

  @Test(".image with a stored blob pastes the raw bytes read from BlobStore")
  func imageWithBlobPastesBytes() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "an image", blobPath: blobPath)

    let result = await viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .image(imageBytes))
  }

  @Test(".image ignores plainText — images have no plain form, so it pastes normally")
  func imageIgnoresPlainTextFlag() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "an image", blobPath: blobPath)

    let result = await viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .image(imageBytes))
  }

  @Test(".image with no stored blobPath returns nil (nothing safe to paste)")
  func imageWithoutBlobPathReturnsNil() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .image, previewText: "an image", blobPath: nil)

    #expect(await viewModel.pasteContent(for: item, plainText: false) == nil)
  }

  @Test(".image whose blob is missing on disk returns nil rather than crashing")
  func imageWithMissingBlobReturnsNil() async {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "an image", blobPath: "blobs/does-not-exist")

    #expect(await viewModel.pasteContent(for: item, plainText: false) == nil)
  }

  @Test(".file with a valid fileReference re-offers the original file's URL")
  func fileWithReferenceReturnsFileURL() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(
      kind: .file, previewText: "example.txt", fileReference: "file:///tmp/example.txt")

    #expect(
      await viewModel.pasteContent(for: item, plainText: false)
        == .file(URL(string: "file:///tmp/example.txt")!))
  }

  @Test(".file with no fileReference returns nil")
  func fileWithoutReferenceReturnsNil() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .file, previewText: "example.txt", fileReference: nil)

    #expect(await viewModel.pasteContent(for: item, plainText: false) == nil)
  }

  @Test(".file ignores plainText — files have no plain form, so it pastes normally")
  func fileIgnoresPlainTextFlag() async {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(
      kind: .file, previewText: "example.txt", fileReference: "file:///tmp/example.txt")

    #expect(
      await viewModel.pasteContent(for: item, plainText: true)
        == .file(URL(string: "file:///tmp/example.txt")!))
  }

  // MARK: - .image + ocrText (T-OCR2)

  @Test(
    "plainText: true on an .image WITH recognized text pastes the recognized text, not the image"
  )
  func imageWithRecognizedTextPlainTextPastesOcrText() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "a screenshot", blobPath: blobPath,
      ocrText: "Invoice #4471 — Total Due")

    let result = await viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .text("Invoice #4471 — Total Due"))
  }

  @Test(
    "plainText: false on an .image WITH recognized text still pastes the image itself, not the text"
  )
  func imageWithRecognizedTextNonPlainPastesImage() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "a screenshot", blobPath: blobPath,
      ocrText: "Invoice #4471 — Total Due")

    let result = await viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .image(imageBytes))
  }

  @Test(
    "plainText: true on an .image with NO recognized text falls back to pasting the image (no plain form)"
  )
  func imageWithoutRecognizedTextPlainTextFallsBackToImage() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "no OCR yet", blobPath: blobPath, ocrText: nil)

    let result = await viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .image(imageBytes))
  }

  @Test(
    "plainText: true on an .image whose recognized text is empty falls back to pasting the image"
  )
  func imageWithEmptyRecognizedTextPlainTextFallsBackToImage() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "empty OCR", blobPath: blobPath, ocrText: "")

    let result = await viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .image(imageBytes))
  }
}

// MARK: - copyRecognizedText (T-OCR2)

@MainActor
@Suite("PickerViewModel.copyRecognizedText")
struct PickerViewModelCopyRecognizedTextTests {

  @Test("Copies the item's recognized text to the pasteboard and suppresses the self-write")
  func copiesRecognizedTextToPasteboard() {
    let pasteboard = FakePasteboardWriting()
    let viewModel = makeTestPickerViewModel(pasteboard: pasteboard)
    var suppressedChangeCount: Int?
    viewModel.suppressOwnPasteboardWrite = { suppressedChangeCount = $0 }
    let item = makeClipItem(kind: .image, ocrText: "Recognized screenshot text")

    viewModel.copyRecognizedText(from: item)

    #expect(pasteboard.writtenString == "Recognized screenshot text")
    #expect(pasteboard.writeCount == 1)
    #expect(suppressedChangeCount == pasteboard.changeCount)
  }

  @Test("Does nothing when the item has no recognized text")
  func noOpWhenNoRecognizedText() {
    let pasteboard = FakePasteboardWriting()
    let viewModel = makeTestPickerViewModel(pasteboard: pasteboard)
    let item = makeClipItem(kind: .image, ocrText: nil)

    viewModel.copyRecognizedText(from: item)

    #expect(pasteboard.writeCount == 0)
  }

  @Test("Does nothing when the item's recognized text is empty")
  func noOpWhenRecognizedTextEmpty() {
    let pasteboard = FakePasteboardWriting()
    let viewModel = makeTestPickerViewModel(pasteboard: pasteboard)
    let item = makeClipItem(kind: .image, ocrText: "")

    viewModel.copyRecognizedText(from: item)

    #expect(pasteboard.writeCount == 0)
  }
}

// MARK: - resolvedSelection (SelectionPolicy outcomes)

@MainActor
@Suite("PickerViewModel.resolvedSelection")
struct PickerViewModelResolvedSelectionTests {

  @Test(".hardReset always selects the new first result and requests a scroll-to-top")
  func hardResetSelectsFirstResult() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .hardReset, currentID: items[2].id, result: items)

    #expect(id == items[0].id)
    #expect(scrollToTop)
  }

  @Test(".hardReset against an empty result selects nothing but still requests a scroll-to-top")
  func hardResetEmptyResultSelectsNil() {
    let viewModel = makeTestPickerViewModel()

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .hardReset, currentID: UUID(), result: [ClipItem]())

    #expect(id == nil)
    #expect(scrollToTop)
  }

  @Test(".softReconcile keeps the current selection when it's still present in the new result")
  func softReconcileKeepsCurrentSelectionWhenStillPresent() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .softReconcile, currentID: items[1].id, result: items)

    #expect(id == items[1].id)
    #expect(!scrollToTop)
  }

  @Test(
    "`.softReconcile` falls back to the first result (and requests a scroll-to-top) when the current selection is no longer present"
  )
  func softReconcileFallsBackWhenCurrentSelectionGone() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .softReconcile, currentID: UUID(), result: items)

    #expect(id == items[0].id)
    #expect(scrollToTop)
  }

  @Test("`.softReconcile` with no prior selection falls back to the first result")
  func softReconcileWithNilCurrentIDFallsBackToFirst() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .softReconcile, currentID: nil, result: items)

    #expect(id == items[0].id)
    #expect(scrollToTop)
  }

  @Test("`.softReconcile` against an empty result selects nothing but still scrolls to top")
  func softReconcileEmptyResultSelectsNil() {
    let viewModel = makeTestPickerViewModel()

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .softReconcile, currentID: nil, result: [ClipItem]())

    #expect(id == nil)
    #expect(scrollToTop)
  }

  @Test("`.selectNear` against an empty result selects nothing and does NOT scroll to top")
  func selectNearEmptyResultSelectsNilNoScroll() {
    let viewModel = makeTestPickerViewModel()

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .selectNear(previousIndex: 1), currentID: nil, result: [ClipItem]())

    #expect(id == nil)
    #expect(!scrollToTop)
  }

  @Test(
    "`.selectNear(previousIndex: nil)` falls back to softReconcile's policy — keeps the current selection if still present"
  )
  func selectNearNilIndexFallsBackToSoftReconcileKeepsCurrent() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .selectNear(previousIndex: nil), currentID: items[2].id, result: items)

    #expect(id == items[2].id)
    #expect(!scrollToTop)
  }

  @Test(
    "`.selectNear(previousIndex: nil)` falls back to softReconcile's policy — selects the first result if the current selection is gone"
  )
  func selectNearNilIndexFallsBackToSoftReconcileFirstWhenGone() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .selectNear(previousIndex: nil), currentID: UUID(), result: items)

    #expect(id == items[0].id)
    #expect(scrollToTop)
  }

  @Test("`.selectNear(previousIndex:)` within bounds selects the element now at that index")
  func selectNearWithinBoundsSelectsThatIndex() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem(), makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .selectNear(previousIndex: 2), currentID: nil, result: items)

    #expect(id == items[2].id)
    #expect(!scrollToTop)
  }

  @Test(
    "`.selectNear(previousIndex:)` past the end of a now-shorter result clamps to the last element"
  )
  func selectNearIndexPastEndClampsToLast() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .selectNear(previousIndex: 99), currentID: nil, result: items)

    #expect(id == items[2].id)
    #expect(!scrollToTop)
  }

  @Test("`.selectNear(previousIndex:)` below zero clamps to the first element")
  func selectNearNegativeIndexClampsToFirst() {
    let viewModel = makeTestPickerViewModel()
    let items = [makeClipItem(), makeClipItem()]

    let (id, scrollToTop) = viewModel.resolvedSelection(
      .selectNear(previousIndex: -5), currentID: nil, result: items)

    #expect(id == items[0].id)
    #expect(!scrollToTop)
  }
}

// MARK: - Tab → ClipScope mapping (History vs. Pinned query pipeline)

@MainActor
@Suite("PickerViewModel tab/scope query mapping")
struct PickerViewModelScopeMappingTests {

  @Test(
    "The History tab queries only unpinned items and the Pinned tab queries only pinned items, driven purely by activeTab"
  )
  func tabSwitchQueriesTheMatchingScope() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let pinnedItem = makeClipItem(
      previewText: "pinned-item", pinned: true, pinnedAt: Date())
    let unpinnedItem = makeClipItem(previewText: "unpinned-item")
    _ = try await clipStore.insertOrBumpDuplicate(pinnedItem)
    _ = try await clipStore.insertOrBumpDuplicate(unpinnedItem)

    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == unpinnedItem.id } }
    #expect(viewModel.activeTab == .history)
    #expect(viewModel.rows.map(\.id) == [unpinnedItem.id])

    viewModel.activeTab = .pinned
    await waitUntil { viewModel.rows.contains { $0.id == pinnedItem.id } }
    #expect(viewModel.rows.map(\.id) == [pinnedItem.id])

    viewModel.activeTab = .history
    await waitUntil { viewModel.rows.contains { $0.id == unpinnedItem.id } }
    #expect(viewModel.rows.map(\.id) == [unpinnedItem.id])
  }
}

// MARK: - highlightedItemCapabilities (T-SET2, widened T-SET4)

@MainActor
@Suite("PickerViewModel.highlightedItemCapabilities")
struct PickerViewModelHighlightedItemCapabilitiesTests {

  @Test("altEnterHint is .ocrText when the highlighted row is an .image with recognized text")
  func ocrTextForImageWithRecognizedText() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "a screenshot", ocrText: "Invoice #4471")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    #expect(viewModel.highlightedItemCapabilities.altEnterHint == .ocrText)
  }

  @Test("altEnterHint is nil when the highlighted row is an .image with no recognized text")
  func nilForImageWithoutRecognizedText() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "no OCR yet", ocrText: nil)
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    #expect(viewModel.highlightedItemCapabilities.altEnterHint == nil)
    #expect(!viewModel.highlightedItemCapabilities.supportsSaveAsSnippet)
  }

  @Test("altEnterHint is nil and ⌘S is supported for a highlighted .text row")
  func textRowSupportsSaveNotAltEnter() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(kind: .text, previewText: "just text")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    #expect(viewModel.highlightedItemCapabilities.altEnterHint == nil)
    #expect(viewModel.highlightedItemCapabilities.supportsSaveAsSnippet)
  }

  @Test("⌘S is not supported for a highlighted .image row (T-SET4 bug report)")
  func imageRowDoesNotSupportSave() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "a screenshot")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    #expect(!viewModel.highlightedItemCapabilities.supportsSaveAsSnippet)
  }

  @Test("nil altEnterHint, ⌘S not supported when nothing is highlighted (selectedItemID is nil)")
  func nothingHighlighted() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)

    viewModel.willShow()
    viewModel.selectedItemID = nil

    #expect(viewModel.highlightedItemCapabilities.altEnterHint == nil)
    #expect(!viewModel.highlightedItemCapabilities.supportsSaveAsSnippet)
  }

  @Test("nil altEnterHint, ⌘S not supported on the Snippets tab regardless of highlighted snippet")
  func snippetsTabAlwaysNilCapabilities() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snippetStore = InMemorySnippetStore()
    let snippet = Snippet(title: "Greeting", body: "Hello there")
    _ = try await snippetStore.create(snippet)
    let viewModel = makeTestPickerViewModel(snippetStore: snippetStore, blobStore: blobStore)

    viewModel.willShow()
    viewModel.activeTab = .snippets
    await waitUntil { viewModel.snippetRows.contains { $0.id == snippet.id } }
    viewModel.selectedSnippetID = snippet.id

    #expect(viewModel.highlightedItemCapabilities.altEnterHint == nil)
    #expect(!viewModel.highlightedItemCapabilities.supportsSaveAsSnippet)
  }
}

// MARK: - saveHighlightedAsSnippet / presentSaveAsSnippetForm (T-SET4)

@MainActor
@Suite("PickerViewModel.saveHighlightedAsSnippet")
struct PickerViewModelSaveHighlightedAsSnippetTests {

  @Test("no-ops on a highlighted .image row — does not open the snippet editor")
  func noOpForImageRow() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "a screenshot")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)
    var presentedModes: [SnippetFormMode] = []
    viewModel.presentSnippetEditor = { presentedModes.append($0) }

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    viewModel.saveHighlightedAsSnippet()
    // Give the internal `Task` (flush + guard) a chance to run — there's no
    // observable state change to `waitUntil` on for a true no-op, so this
    // polls a couple of run-loop turns before asserting nothing happened.
    for _ in 0..<5 { await Task.yield() }

    #expect(presentedModes.isEmpty)
  }

  @Test("no-ops on a highlighted .richText row — does not open the snippet editor")
  func noOpForRichTextRow() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(kind: .richText, previewText: "bold text")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)
    var presentedModes: [SnippetFormMode] = []
    viewModel.presentSnippetEditor = { presentedModes.append($0) }

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    viewModel.saveHighlightedAsSnippet()
    for _ in 0..<5 { await Task.yield() }

    #expect(presentedModes.isEmpty)
  }

  @Test("no-ops on a highlighted .file row — does not open the snippet editor")
  func noOpForFileRow() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(
      kind: .file, previewText: "report.pdf", fileReference: "file:///tmp/report.pdf")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)
    var presentedModes: [SnippetFormMode] = []
    viewModel.presentSnippetEditor = { presentedModes.append($0) }

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    viewModel.saveHighlightedAsSnippet()
    for _ in 0..<5 { await Task.yield() }

    #expect(presentedModes.isEmpty)
  }

  @Test("opens the snippet editor for a highlighted .text row (the supported case)")
  func opensEditorForTextRow() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let item = makeClipItem(kind: .text, previewText: "save me")
    _ = try await clipStore.insertOrBumpDuplicate(item)
    let viewModel = makeTestPickerViewModel(clipStore: clipStore, blobStore: blobStore)
    var presentedModes: [SnippetFormMode] = []
    viewModel.presentSnippetEditor = { presentedModes.append($0) }

    viewModel.willShow()
    await waitUntil { viewModel.rows.contains { $0.id == item.id } }
    viewModel.selectedItemID = item.id

    viewModel.saveHighlightedAsSnippet()
    await waitUntil { !presentedModes.isEmpty }

    #expect(presentedModes.count == 1)
    if case .createFromClip(let previewText) = presentedModes.first {
      #expect(previewText == "save me")
    } else {
      Issue.record("Expected .createFromClip, got \(String(describing: presentedModes.first))")
    }
  }
}

// MARK: - openSettingsFromPicker (T-SET5)
//
// `openSettingsFromPicker()` is the one piece of the ⌘, fix that's pure
// sequencing logic reachable from a test — `PickerView.handle(_:)`'s actual
// ⌘, key-dispatch case, and whether `@Environment(\.openSettings)` +
// `SettingsFocusCoordinator.focusAfterOpening()` genuinely raise a real
// window, are not (SwiftUI key routing + a live window server — see this
// task's manual-verification writeup). What's tested here is the part that
// is pure: dismissing the picker before handing off to `openSettings()`,
// via the same injected-closure spy pattern `dismiss`/`presentSnippetEditor`
// are already tested with elsewhere in this file.

@MainActor
@Suite("PickerViewModel.openSettingsFromPicker")
struct PickerViewModelOpenSettingsFromPickerTests {

  @Test("dismisses the picker, then opens Settings, in that order")
  func dismissesThenOpensSettings() {
    let viewModel = makeTestPickerViewModel()
    var calls: [String] = []
    viewModel.dismiss = { calls.append("dismiss") }
    viewModel.openSettings = { calls.append("openSettings") }

    viewModel.openSettingsFromPicker()

    #expect(calls == ["dismiss", "openSettings"])
  }

  @Test("still opens Settings even if dismiss is a no-op (default in previews/tests)")
  func opensSettingsEvenWithDefaultDismiss() {
    let viewModel = makeTestPickerViewModel()
    var openSettingsCallCount = 0
    viewModel.openSettings = { openSettingsCallCount += 1 }

    viewModel.openSettingsFromPicker()

    #expect(openSettingsCallCount == 1)
  }
}
