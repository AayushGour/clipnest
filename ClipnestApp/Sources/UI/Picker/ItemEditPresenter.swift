// ItemEditPresenter.swift
//
// T-EDIT7: macOS glue between `PickerViewModel.presentItemEditor` and
// `ItemEditorWindow`. It exists as a type (rather than a closure in
// `AppEnvironment.init`) because `PickerViewModel.presentItemEditor` is a
// required `let` init seam, but the presenter needs the view model and the
// picker panel, which are built after it — so those two are `weak` properties
// assigned post-construction (the same cycle `presentSnippetEditor` solves by
// reassigning a `var`).
//
// Re-entry: at most ONE editor is ever open. Asking to edit while the editor
// is already up (or still loading its source) brings the open window forward
// and does nothing else — it never replaces the open editor's `onClose`.

import AppKit
import ClipnestCore
import ClipnestViewModels

@MainActor
final class ItemEditPresenter {
  private let coordinator: ItemEditCoordinator
  let window: ItemEditorWindow
  private var isLoadingSource = false

  weak var viewModel: PickerViewModel?
  weak var panel: PickerPanel?

  init(coordinator: ItemEditCoordinator, window: ItemEditorWindow) {
    self.coordinator = coordinator
    self.window = window
  }

  func present(_ mode: ItemEditMode) {
    guard !window.isVisible, !isLoadingSource else {
      window.bringToFront()
      return
    }
    isLoadingSource = true
    let item: ClipItem
    switch mode {
    case .content(let clip), .recognizedText(let clip): item = clip
    }
    Task { [weak self] in
      guard let self else { return }
      let source = await coordinator.loadSource(for: item)
      // RTF parse + lossy round trip can be slow: off main, only the finished
      // value comes back. Recognized-text editing never parses a blob.
      let rtf: Data?
      switch mode {
      case .content: rtf = source.richBlob
      case .recognizedText: rtf = nil
      }
      let plainText = source.plainText
      let loaded = await Task.detached(priority: .utility) {
        MacEditableRichText.load(rtf: rtf, plainText: plainText)
      }.value
      isLoadingSource = false
      show(mode: mode, item: item, loaded: loaded, richContentMissing: source.richContentMissing)
    }
  }

  private func show(
    mode: ItemEditMode, item: ClipItem, loaded: MacEditableRichText.Loaded,
    richContentMissing: Bool
  ) {
    let coordinator = coordinator
    window.show(
      mode: mode,
      loaded: loaded,
      richContentMissing: richContentMissing,
      pickerPanel: panel,
      save: { output in
        switch mode {
        case .content:
          return await coordinator.saveContent(of: item, output: output)
        case .recognizedText:
          return await coordinator.saveRecognizedText(of: item, text: output.plainText)
        }
      },
      onSaved: { [weak viewModel] in viewModel?.reloadAfterEdit() },
      // Same as the snippet editor: re-key the picker and refocus search so
      // the user lands back in a usable picker.
      onClose: { [weak panel, weak viewModel] in
        panel?.rekeyAfterEditorClose { viewModel?.refocusSearchField() }
      }
    )
  }
}
