// PickerTab.swift
//
// Plan task T23: the picker's tab model. Extracted out of
// `ClipnestApp/Sources/UI/Picker/TabSwitcher.swift` during the P5 view-model
// extraction (Phase 3, Linux port) — `PickerViewModel.activeTab: PickerTab`
// is a hard compile dependency of the now-shared `PickerViewModel`, but
// `TabSwitcher` (the SwiftUI segmented control itself) stays in
// `ClipnestApp` (it's a `View`, `import SwiftUI`). `TabSwitcher.swift` now
// imports `ClipnestViewModels` for this type instead of declaring it
// locally — no duplicate definition, no behavior change.
public enum PickerTab: Int, CaseIterable, Identifiable, Sendable {
  case history
  case pinned
  case snippets

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .history: return "History"
    case .pinned: return "Pinned"
    case .snippets: return "Snippets"
    }
  }
}
