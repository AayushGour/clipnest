// LinuxItemEditPresenter.swift
//
// T-EDIT9: Linux glue between `PickerViewModel.presentItemEditor` and
// `ItemEditorWindow` -- the counterpart of macOS's `ItemEditPresenter`. It is
// a type rather than a closure in `LinuxAppEnvironment.init` because
// `presentItemEditor` is a required init seam while the presenter needs the
// view model and picker window, which are built after it; those two are
// `weak` properties assigned post-construction.
//
// Re-entry: at most ONE editor is ever open. Asking to edit while the editor
// is open, or still loading its source, brings the open window forward and
// does nothing else -- it never replaces the open editor's `onClose`.
import ClipnestCore
import ClipnestGTK
import ClipnestPlatformLinux
import ClipnestViewModels
import Foundation

@MainActor
final class LinuxItemEditPresenter {
  private let coordinator: ItemEditCoordinator
  let window: ItemEditorWindow
  private var isLoadingSource = false

  weak var viewModel: PickerViewModel?
  weak var pickerWindow: PickerWindow?

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
      // HTML parsing of arbitrary clipboard content runs off the main thread.
      let initial: EditableRichText
      switch mode {
      case .content:
        initial = await Task.detached(priority: .utility) {
          LinuxEditableRichText.load(
            blob: source.richBlob, plainText: source.plainText,
            richContentMissing: source.richContentMissing)
        }.value
      case .recognizedText:
        initial = EditableRichText(
          runs: [StyledRun(text: source.plainText)], isLossy: false)
      }
      isLoadingSource = false
      show(mode: mode, item: item, initial: initial)
    }
  }

  private func show(mode: ItemEditMode, item: ClipItem, initial: EditableRichText) {
    let coordinator = coordinator
    // Same as the snippet editor: a real activating window makes the picker's
    // own `notify::is-active` fire false, which would dismiss it. The flag is
    // cleared inside `refocusAfterEditorClose()`.
    pickerWindow?.setEditorSessionActive(true)
    window.show(
      mode: mode,
      initial: initial,
      transientParent: pickerWindow?.transientParentWindow,
      save: { output in
        switch mode {
        case .content:
          return await coordinator.saveContent(of: item, output: output)
        case .recognizedText:
          return await coordinator.saveRecognizedText(of: item, text: output.plainText)
        }
      },
      onSaved: { [weak viewModel] in viewModel?.reloadAfterEdit() },
      onClose: { [weak pickerWindow] in pickerWindow?.refocusAfterEditorClose() })
  }
}
