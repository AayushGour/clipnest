// PickerViewModelAuditShortcutTests.swift
//
// T-AUD-KBD: edit-highlighted-snippet and the explicit preview toggle.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

private let settleDelay = Duration.milliseconds(120)

@MainActor
@Suite("PickerViewModel audit shortcuts (T-AUD-KBD)")
struct PickerViewModelAuditShortcutTests {
  private func makeLoaded(
    previewSetting: Bool = false, snippet: Snippet? = nil
  ) async throws -> PickerViewModel {
    let (_, blobStore) = makeTempBlobStore()
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let snippetStore = InMemorySnippetStore()
    for text in ["one", "two"] {
      _ = try await clipStore.insertOrBumpDuplicate(makeClipItem(previewText: text))
    }
    if let snippet { _ = try await snippetStore.create(snippet) }
    let viewModel = makeTestPickerViewModel(
      clipStore: clipStore, snippetStore: snippetStore, blobStore: blobStore,
      showPreviewOnKeyboardSelection: { previewSetting })
    viewModel.willShow()
    await waitUntil { viewModel.rows.count == 2 && viewModel.selectedItemID != nil }
    return viewModel
  }

  @Test("editHighlightedSnippet opens the editor for the highlighted snippet")
  func editsHighlightedSnippet() async throws {
    let snippet = Snippet(title: "Sig", body: "Best")
    let viewModel = try await makeLoaded(snippet: snippet)
    var modes: [SnippetFormMode] = []
    viewModel.presentSnippetEditor = { modes.append($0) }
    viewModel.activeTab = .snippets
    await waitUntil { viewModel.selectedSnippetID != nil }
    viewModel.editHighlightedSnippet()
    #expect(modes.count == 1)
    guard case .edit(let presented)? = modes.first else {
      Issue.record("expected .edit mode")
      return
    }
    #expect(presented.id == snippet.id)
  }

  @Test("editHighlightedSnippet is a no-op off the Snippets tab")
  func editNoOpOnHistory() async throws {
    let viewModel = try await makeLoaded(snippet: Snippet(title: "Sig", body: "Best"))
    var count = 0
    viewModel.presentSnippetEditor = { _ in count += 1 }
    viewModel.editHighlightedSnippet()
    #expect(count == 0)
  }

  @Test("toggle previews the selected row even with the setting OFF, then closes")
  func toggleOpensAndCloses() async throws {
    let viewModel = try await makeLoaded(previewSetting: false)
    viewModel.togglePreviewForHighlighted()
    await waitUntil { viewModel.previewTargetSource == .selection }
    #expect(viewModel.previewTargetID == viewModel.selectedItemID)

    viewModel.togglePreviewForHighlighted()
    await waitUntil { viewModel.previewTargetID == nil }
    #expect(viewModel.previewTargetSource == nil)
  }

  @Test("a forced preview follows arrow moves, and ends when the picker hides")
  func forcedPreviewFollowsSelectionThenResets() async throws {
    let viewModel = try await makeLoaded(previewSetting: false)
    viewModel.togglePreviewForHighlighted()
    await waitUntil { viewModel.previewTargetSource == .selection }
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    await waitUntil { viewModel.previewTargetID == viewModel.selectedItemID }
    #expect(viewModel.previewTargetSource == .selection)

    viewModel.didHide()
    #expect(viewModel.previewTargetID == nil)
    #expect(!viewModel.selectionPreviewForced)
    // Arrowing afterwards does NOT preview again (setting is OFF).
    viewModel.willShow()
    viewModel.selectionChangedForPreview()
    try await Task.sleep(for: settleDelay)
    #expect(viewModel.previewTargetID == nil)
  }
}
