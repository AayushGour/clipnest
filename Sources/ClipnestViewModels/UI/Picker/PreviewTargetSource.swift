// PreviewTargetSource.swift
//
// T-PREVIEWSEL1: why `PickerViewModel.previewTargetID` points where it does,
// so a platform view knows which row to anchor the preview popover to.

/// What put a row into `PickerViewModel.previewTargetID`.
public enum PreviewTargetSource: Equatable, Sendable {
  /// The pointer is over the row — anchor to that row / the pointer.
  case hover
  /// The row is the keyboard-selected one (setting ON, no row hovered) —
  /// anchor to the selected row, not the pointer.
  case selection
}
