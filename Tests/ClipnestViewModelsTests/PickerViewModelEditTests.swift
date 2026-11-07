// PickerViewModelEditTests.swift
//
// T-EDIT4: pins `PickerViewModel.presentEditForm(for:)` gating (only the
// `ClipItem` predicates decide what is editable) and `reloadAfterEdit()`
// (the explicit refresh the editor triggers, since external `.updated`
// changes are deliberately ignored by the store-change handler).

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

@MainActor
@Suite("PickerViewModel edit seam (T-EDIT4)")
struct PickerViewModelEditTests {

  private final class ModeRecorder {
    var modes: [ItemEditMode] = []
  }

  private func makeViewModel(
    recorder: ModeRecorder,
    clipStore: any ClipStore = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore)
  ) -> PickerViewModel {
    makeTestPickerViewModel(
      clipStore: clipStore,
      presentItemEditor: { recorder.modes.append($0) })
  }

  @Test("Text, rich text and link items open the content editor, exactly once each")
  func editFormOpensContentModeForTextRichTextAndLink() {
    for kind in [ItemKind.text, .richText, .link] {
      let recorder = ModeRecorder()
      let viewModel = makeViewModel(recorder: recorder)
      let item = makeClipItem(kind: kind, previewText: "hello")
      viewModel.presentEditForm(for: item)
      #expect(recorder.modes == [.content(item)])
    }
  }

  @Test("An image with recognized text opens the recognized-text editor")
  func editFormOpensRecognizedModeForImageWithOCR() {
    let recorder = ModeRecorder()
    let viewModel = makeViewModel(recorder: recorder)
    let item = makeClipItem(kind: .image, previewText: "Image", ocrText: "scanned words")
    viewModel.presentEditForm(for: item)
    #expect(recorder.modes == [.recognizedText(item)])
  }

  @Test("Files and images without recognized text never open an editor")
  func editFormDoesNothingForFileAndOcrlessImage() {
    let recorder = ModeRecorder()
    let viewModel = makeViewModel(recorder: recorder)
    viewModel.presentEditForm(for: makeClipItem(kind: .file, fileReference: "/tmp/a.txt"))
    viewModel.presentEditForm(for: makeClipItem(kind: .image, ocrText: nil))
    viewModel.presentEditForm(for: makeClipItem(kind: .image, ocrText: ""))
    #expect(recorder.modes.isEmpty)
  }

  // MARK: - editHighlighted (T-EDIT13)

  private func highlight(_ item: ClipItem, in store: InMemoryClipStore, _ vm: PickerViewModel)
    async throws
  {
    _ = try await store.insertOrBumpDuplicate(item)
    vm.willShow()
    await waitUntil { vm.rows.contains { $0.id == item.id } }
    vm.selectedItemID = item.id
  }

  @Test("editHighlighted on a text row presents the content editor")
  func editHighlightedTextRow() async throws {
    let recorder = ModeRecorder()
    let store = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore)
    let viewModel = makeViewModel(recorder: recorder, clipStore: store)
    let item = makeClipItem(kind: .text, previewText: "hello")
    try await highlight(item, in: store, viewModel)
    viewModel.editHighlighted()
    #expect(recorder.modes.count == 1)
    #expect(recorder.modes.first.map { if case .content = $0 { true } else { false } } == true)
  }

  @Test("editHighlighted on an OCR image presents the recognized-text editor")
  func editHighlightedOcrImage() async throws {
    let recorder = ModeRecorder()
    let store = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore)
    let viewModel = makeViewModel(recorder: recorder, clipStore: store)
    try await highlight(
      makeClipItem(kind: .image, previewText: "Image", ocrText: "words"), in: store, viewModel)
    viewModel.editHighlighted()
    #expect(recorder.modes.count == 1)
    #expect(
      recorder.modes.first.map { if case .recognizedText = $0 { true } else { false } } == true)
  }

  @Test("editHighlighted on a file or OCR-less image presents nothing")
  func editHighlightedNonEditable() async throws {
    let recorder = ModeRecorder()
    let store = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore)
    let viewModel = makeViewModel(recorder: recorder, clipStore: store)
    try await highlight(
      makeClipItem(kind: .file, fileReference: "/tmp/a.txt"), in: store, viewModel)
    viewModel.editHighlighted()
    let image = makeClipItem(kind: .image, ocrText: nil)
    try await highlight(image, in: store, viewModel)
    viewModel.editHighlighted()
    #expect(recorder.modes.isEmpty)
  }

  @Test("editHighlighted with nothing highlighted presents nothing")
  func editHighlightedNothingHighlighted() async throws {
    let recorder = ModeRecorder()
    let store = InMemoryClipStore(blobStore: makeTempBlobStore().blobStore)
    let viewModel = makeViewModel(recorder: recorder, clipStore: store)
    try await highlight(makeClipItem(kind: .text, previewText: "x"), in: store, viewModel)
    viewModel.selectedItemID = nil
    viewModel.editHighlighted()
    #expect(recorder.modes.isEmpty)
  }

  @Test("editHighlighted on the Snippets tab opens the highlighted snippet's edit form")
  func editHighlightedSnippet() async throws {
    let recorder = ModeRecorder()
    let snippetStore = InMemorySnippetStore()
    let snippet = Snippet(title: "Greeting", body: "Hello")
    _ = try await snippetStore.create(snippet)
    let viewModel = makeTestPickerViewModel(
      snippetStore: snippetStore, presentItemEditor: { recorder.modes.append($0) })
    var snippetModes: [SnippetFormMode] = []
    viewModel.presentSnippetEditor = { snippetModes.append($0) }
    viewModel.willShow()
    viewModel.activeTab = .snippets
    await waitUntil { viewModel.snippetRows.contains { $0.id == snippet.id } }
    viewModel.selectedSnippetID = snippet.id
    viewModel.editHighlighted()
    #expect(snippetModes.count == 1)
    #expect(recorder.modes.isEmpty)
    viewModel.selectedSnippetID = nil
    viewModel.editHighlighted()
    #expect(snippetModes.count == 1)
  }

  @Test("reloadAfterEdit re-queries rows, keeping position and pin state")
  func reloadAfterEditRequeriesRowsKeepingPositionAndPin() async throws {
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = InMemoryClipStore(blobStore: blobStore)
    // Pinned items only appear on the Pinned tab, so the edited row's
    // surviving pin is observable as it still being listed there.
    let now = Date()
    let first = try await store.insertOrBumpDuplicate(
      makeClipItem(previewText: "first", pinned: true, pinnedAt: now))
    let target = try await store.insertOrBumpDuplicate(
      makeClipItem(previewText: "before edit", pinned: true, pinnedAt: now.addingTimeInterval(1)))
    _ = try await store.insertOrBumpDuplicate(
      makeClipItem(previewText: "last", pinned: true, pinnedAt: now.addingTimeInterval(2)))

    let viewModel = makeTestPickerViewModel(clipStore: store, blobStore: blobStore)
    viewModel.willShow()
    viewModel.activeTab = .pinned
    await waitUntil { viewModel.rows.count == 3 }
    let indexBefore = try #require(viewModel.rows.firstIndex { $0.id == target.id })

    let derived = ClipContentDerivation.plainText("after edit")
    _ = try await store.updateContent(
      target.id, with: ClipContentUpdate(derived: derived, blobPath: nil))
    viewModel.reloadAfterEdit()

    await waitUntil { viewModel.rows.contains { $0.previewText == "after edit" } }
    let indexAfter = try #require(viewModel.rows.firstIndex { $0.id == target.id })
    #expect(indexAfter == indexBefore)
    #expect(viewModel.rows[indexAfter].previewText == "after edit")
    #expect(viewModel.rows[indexAfter].pinned)
    #expect(viewModel.rows.contains { $0.id == first.id })
  }
}
