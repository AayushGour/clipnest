// SnippetFormMode.swift
//
// Extracted out of `ClipnestApp/Sources/UI/Picker/SnippetFormView.swift`
// during the P5 view-model extraction (Phase 3, Linux port) —
// `PickerViewModel.presentSnippetEditor: (SnippetFormMode) -> Void` and its
// `presentCreateSnippetForm()`/`presentEditSnippetForm(_:)`/
// `presentSaveAsSnippetForm(from:)` are hard compile dependencies of the now-
// shared `PickerViewModel`, but `SnippetFormView` (the SwiftUI form itself)
// stays in `ClipnestApp` (a `View`). `SnippetFormView.swift` now imports
// `ClipnestViewModels` for this type instead of declaring it locally — no
// duplicate definition, no behavior change.
import ClipnestCore

public enum SnippetFormMode: Sendable {
  case create
  case createFromClip(String)
  case edit(Snippet)

  public var isNew: Bool {
    switch self {
    case .create, .createFromClip: return true
    case .edit: return false
    }
  }
}
