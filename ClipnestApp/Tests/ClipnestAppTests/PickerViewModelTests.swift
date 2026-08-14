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
  func textPastesPreviewText() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .text, previewText: "hello world")

    #expect(viewModel.pasteContent(for: item, plainText: false) == .text("hello world"))
  }

  @Test(".text ignores plainText — there's no richer form to strip")
  func textIgnoresPlainTextFlag() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .text, previewText: "hello world")

    #expect(viewModel.pasteContent(for: item, plainText: true) == .text("hello world"))
  }

  @Test(".link pastes its previewText verbatim")
  func linkPastesPreviewText() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .link, previewText: "https://example.com")

    #expect(
      viewModel.pasteContent(for: item, plainText: false) == .text("https://example.com"))
  }

  @Test(".link ignores plainText — there's no richer form to strip")
  func linkIgnoresPlainTextFlag() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .link, previewText: "https://example.com")

    #expect(viewModel.pasteContent(for: item, plainText: true) == .text("https://example.com"))
  }

  @Test(".richText with a stored RTF blob pastes the rich form (RTF bytes + plain fallback)")
  func richTextWithBlobPastesRich() throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rtfBytes = Data("{\\rtf1\\ansi bold}".utf8)
    let blobPath = try blobStore.write(rtfBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .richText, previewText: "bold", blobPath: blobPath)

    let result = viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .richText(rtf: rtfBytes, plain: "bold"))
  }

  @Test(
    "`plainText: true` strips .richText to its plain previewText, even though a valid RTF blob is stored"
  )
  func richTextWithBlobPlainTextStripsToPlain() throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rtfBytes = Data("{\\rtf1\\ansi bold}".utf8)
    let blobPath = try blobStore.write(rtfBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .richText, previewText: "bold", blobPath: blobPath)

    let result = viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .text("bold"))
  }

  @Test("A legacy .richText item with no stored blob falls back to its plain previewText")
  func richTextWithoutBlobFallsBackToPlain() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .richText, previewText: "legacy plain", blobPath: nil)

    let result = viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .text("legacy plain"))
  }

  @Test("A .richText item whose blob is missing on disk falls back to its plain previewText")
  func richTextWithMissingBlobFallsBackToPlain() {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .richText, previewText: "orphaned", blobPath: "blobs/does-not-exist")

    let result = viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .text("orphaned"))
  }

  @Test(".image with a stored blob pastes the raw bytes read from BlobStore")
  func imageWithBlobPastesBytes() throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "an image", blobPath: blobPath)

    let result = viewModel.pasteContent(for: item, plainText: false)

    #expect(result == .image(imageBytes))
  }

  @Test(".image ignores plainText — images have no plain form, so it pastes normally")
  func imageIgnoresPlainTextFlag() throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageBytes = Data([0xFF, 0xD8, 0xFF, 0x00])
    let blobPath = try blobStore.write(imageBytes)
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(kind: .image, previewText: "an image", blobPath: blobPath)

    let result = viewModel.pasteContent(for: item, plainText: true)

    #expect(result == .image(imageBytes))
  }

  @Test(".image with no stored blobPath returns nil (nothing safe to paste)")
  func imageWithoutBlobPathReturnsNil() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .image, previewText: "an image", blobPath: nil)

    #expect(viewModel.pasteContent(for: item, plainText: false) == nil)
  }

  @Test(".image whose blob is missing on disk returns nil rather than crashing")
  func imageWithMissingBlobReturnsNil() {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let viewModel = makeTestPickerViewModel(blobStore: blobStore)
    let item = makeClipItem(
      kind: .image, previewText: "an image", blobPath: "blobs/does-not-exist")

    #expect(viewModel.pasteContent(for: item, plainText: false) == nil)
  }

  @Test(".file with a valid fileReference re-offers the original file's URL")
  func fileWithReferenceReturnsFileURL() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(
      kind: .file, previewText: "example.txt", fileReference: "file:///tmp/example.txt")

    #expect(
      viewModel.pasteContent(for: item, plainText: false)
        == .file(URL(string: "file:///tmp/example.txt")!))
  }

  @Test(".file with no fileReference returns nil")
  func fileWithoutReferenceReturnsNil() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(kind: .file, previewText: "example.txt", fileReference: nil)

    #expect(viewModel.pasteContent(for: item, plainText: false) == nil)
  }

  @Test(".file ignores plainText — files have no plain form, so it pastes normally")
  func fileIgnoresPlainTextFlag() {
    let viewModel = makeTestPickerViewModel()
    let item = makeClipItem(
      kind: .file, previewText: "example.txt", fileReference: "file:///tmp/example.txt")

    #expect(
      viewModel.pasteContent(for: item, plainText: true)
        == .file(URL(string: "file:///tmp/example.txt")!))
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
