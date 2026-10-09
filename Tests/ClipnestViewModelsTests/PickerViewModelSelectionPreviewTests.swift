// PickerViewModelSelectionPreviewTests.swift
//
// T-PREVIEWSEL1: the "show preview when selecting with the keyboard" setting.
// OFF (default) = hover-only, exactly as before; ON = an explicit keyboard
// selection move (`selectionChangedForPreview()`) previews the selected row
// after the same show delay, a hovered row always wins, and nothing that is
// not a keyboard move (open, search reset, tab switch) previews.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

/// Long enough for the 20ms show delay to have elapsed if something WAS going to fire.
private let settleDelay = Duration.milliseconds(120)

@MainActor
@Suite("PickerViewModel keyboard-selection preview (T-PREVIEWSEL1)")
struct PickerViewModelSelectionPreviewTests {

  /// A picker with 3 History rows loaded (newest first), the setting driven by
  /// the returned box, plus `snippet` in the Snippets tab when given.
  private func makeLoaded(
    enabled: Bool, snippet: Snippet? = nil
  ) async throws -> (PickerViewModel, [ClipItem], EnabledBox) {
    let (_, blobStore) = makeTempBlobStore()
    let clipStore = InMemoryClipStore(blobStore: blobStore)
    let snippetStore = InMemorySnippetStore()
    for text in ["one", "two", "three"] {
      _ = try await clipStore.insertOrBumpDuplicate(makeClipItem(previewText: text))
    }
    if let snippet { _ = try await snippetStore.create(snippet) }
    let box = EnabledBox(enabled)
    let viewModel = makeTestPickerViewModel(
      clipStore: clipStore, snippetStore: snippetStore, blobStore: blobStore,
      showPreviewOnKeyboardSelection: { box.value })
    viewModel.willShow()
    await waitUntil { viewModel.rows.count == 3 && viewModel.selectedItemID != nil }
    return (viewModel, viewModel.rows, box)
  }

  @Test("setting OFF: a keyboard selection move never previews")
  func offNeverPreviews() async throws {
    let (viewModel, _, _) = try await makeLoaded(enabled: false)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    try await Task.sleep(for: settleDelay)
    #expect(viewModel.previewTargetID == nil)
    #expect(viewModel.previewTargetSource == nil)
  }

  @Test("setting ON: a keyboard selection move previews the selected row after the delay")
  func onPreviewsSelection() async throws {
    let (viewModel, rows, _) = try await makeLoaded(enabled: true)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    // The delay is real: nothing is shown synchronously.
    #expect(viewModel.previewTargetID == nil)
    await waitUntil { viewModel.previewTargetID != nil }
    #expect(viewModel.previewTargetID == rows[1].id)
    #expect(viewModel.selectedItemID == rows[1].id)
    #expect(viewModel.previewTargetSource == .selection)
  }

  @Test("the setting is read live: flipping it ON mid-session takes effect")
  func settingIsReadLive() async throws {
    let (viewModel, rows, box) = try await makeLoaded(enabled: false)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    try await Task.sleep(for: settleDelay)
    #expect(viewModel.previewTargetID == nil)

    box.value = true
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    await waitUntil { viewModel.previewTargetID != nil }
    #expect(viewModel.previewTargetID == rows[2].id)
  }

  @Test("a hovered row wins over the keyboard selection")
  func hoverWins() async throws {
    let (viewModel, rows, _) = try await makeLoaded(enabled: true)
    viewModel.hoverItem(rows[0].id)
    await waitUntil { viewModel.previewTargetID == rows[0].id }
    #expect(viewModel.previewTargetSource == .hover)

    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    try await Task.sleep(for: settleDelay)
    #expect(viewModel.previewTargetID == rows[0].id)
    #expect(viewModel.previewTargetSource == .hover)
  }

  @Test("leaving hover falls back to the keyboard selection when ON")
  func leavingHoverFallsBackToSelection() async throws {
    let (viewModel, rows, _) = try await makeLoaded(enabled: true)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    viewModel.hoverItem(rows[2].id)
    await waitUntil { viewModel.previewTargetID == rows[2].id }
    #expect(viewModel.previewTargetSource == .hover)

    viewModel.hoverItem(nil)
    await waitUntil { viewModel.previewTargetSource == .selection }
    #expect(viewModel.previewTargetID == rows[1].id)
  }

  @Test("leaving hover closes the preview when OFF (unchanged hover-only behaviour)")
  func leavingHoverClosesWhenOff() async throws {
    let (viewModel, rows, _) = try await makeLoaded(enabled: false)
    viewModel.hoverItem(rows[2].id)
    await waitUntil { viewModel.previewTargetID == rows[2].id }
    viewModel.hoverItem(nil)
    await waitUntil { viewModel.previewTargetID == nil }
    #expect(viewModel.previewTargetSource == nil)
  }

  @Test("opening the picker and the first-page selection settling does not preview")
  func openDoesNotPreview() async throws {
    let (viewModel, _, _) = try await makeLoaded(enabled: true)
    try await Task.sleep(for: settleDelay)
    #expect(viewModel.selectedItemID != nil)
    #expect(viewModel.previewTargetID == nil)
    // Pointer leaving a row on a freshly opened picker must not pull in the
    // default-selected row either: no keyboard move has happened yet.
    viewModel.hoverItem(nil)
    try await Task.sleep(for: .milliseconds(350))
    #expect(viewModel.previewTargetID == nil)
  }

  @Test("a search-text reset after a keyboard preview closes it and does not re-preview")
  func searchResetDoesNotPreview() async throws {
    let (viewModel, _, _) = try await makeLoaded(enabled: true)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    await waitUntil { viewModel.previewTargetSource == .selection }

    viewModel.searchTextChanged("t")
    await waitUntil { viewModel.previewTargetID == nil }
    try await Task.sleep(for: .milliseconds(600))  // debounce + requery settle
    #expect(viewModel.previewTargetID == nil)
  }

  @Test("hiding then re-opening clears the keyboard gate")
  func reopenClearsGate() async throws {
    let (viewModel, _, _) = try await makeLoaded(enabled: true)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    await waitUntil { viewModel.previewTargetSource == .selection }
    viewModel.didHide()
    #expect(viewModel.previewTargetID == nil)
    #expect(viewModel.previewTargetSource == nil)
    viewModel.willShow()
    viewModel.hoverItem(nil)
    try await Task.sleep(for: .milliseconds(350))
    #expect(viewModel.previewTargetID == nil)
  }

  @Test("Snippets tab: the keyboard-selected snippet previews")
  func snippetsTab() async throws {
    let snippet = Snippet(title: "Greeting", body: "Hello there")
    let (viewModel, _, _) = try await makeLoaded(enabled: true, snippet: snippet)
    viewModel.activeTab = .snippets
    await waitUntil { viewModel.snippetRows.contains { row in row.id == snippet.id } }
    viewModel.selectedSnippetID = snippet.id
    // Changing tabs alone is not a keyboard move.
    try await Task.sleep(for: settleDelay)
    #expect(viewModel.previewTargetID == nil)

    viewModel.selectionChangedForPreview()
    await waitUntil { viewModel.previewTargetID != nil }
    #expect(viewModel.previewTargetID == snippet.id)
    #expect(viewModel.previewTargetSource == .selection)
  }

  @Test("changing tabs closes a keyboard preview")
  func tabSwitchCloses() async throws {
    let (viewModel, _, _) = try await makeLoaded(enabled: true)
    viewModel.moveSelection(by: 1)
    viewModel.selectionChangedForPreview()
    await waitUntil { viewModel.previewTargetSource == .selection }
    viewModel.activeTab = .pinned
    await waitUntil { viewModel.previewTargetID == nil }
    #expect(viewModel.previewTargetSource == nil)
  }
}

/// Mutable stand-in for the live `SettingsStore` read.
@MainActor
final class EnabledBox {
  var value: Bool
  init(_ value: Bool) { self.value = value }
}
