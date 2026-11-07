// NSWindow+PickerPlacement.swift
//
// Shared by `SnippetEditorWindow` and `ItemEditorWindow`: both are editor
// panels (`EditorPanel`) opened from the picker and laid out as a
// side-by-side pair with it.

import AppKit
import ClipnestViewModels

extension NSWindow {
  /// Gap, in points, kept between an editor window and the picker panel when
  /// placing the editor beside it.
  private static let pickerPlacementGap: CGFloat = 12

  /// Lays this window out beside `pickerPanel` as a side-by-side pair (see
  /// `WindowPlacement.pairLayout`) — picker on the left, this window to its
  /// right with a gap, top-aligned, both clamped to stay fully on the
  /// picker's screen. **Moves `pickerPanel`'s frame** (shifting it left only
  /// as far as needed, never resizing it) when its current position doesn't
  /// leave room, guaranteeing distinct left edges and — whenever the pair
  /// fits the screen's visible width — zero overlap; a stacked fallback is
  /// deliberately never used. The picker's new position is left as-is once
  /// the editor closes.
  ///
  /// Falls back to centered placement whenever the picker isn't currently
  /// visible (`nil`, or its `screen` is `nil` because it isn't on screen).
  /// Doesn't change this window's size — only `setFrameOrigin`.
  @MainActor
  func positionRelativeToPicker(_ pickerPanel: PickerPanel?) {
    guard let pickerPanel, pickerPanel.isVisible, let screen = pickerPanel.screen else {
      center()
      return
    }
    // Fully qualified: this SDK's `SwiftUI` also declares a public
    // `WindowPlacement`, so the bare name is ambiguous when both imported.
    let (pickerOrigin, editorOrigin) = ClipnestViewModels.WindowPlacement.pairLayout(
      pickerFrame: pickerPanel.frame,
      editorSize: frame.size,
      screenVisibleFrame: screen.visibleFrame,
      gap: Self.pickerPlacementGap
    )
    pickerPanel.setFrameOrigin(pickerOrigin)
    setFrameOrigin(editorOrigin)
  }
}

extension PickerPanel {
  /// Hands key status back to the picker after an editor window closes
  /// (T-EDIT18). Editors report `onClose` from `windowWillClose`, i.e. before
  /// the close finishes, so a synchronous re-key was undone; this defers one
  /// run-loop turn. Skipped if the picker was hidden meanwhile. Sufficient on
  /// its own only because the editors never activate Clipnest (T-EDIT19, see
  /// `EditorPanel`): an app deactivation arriving after this would take the
  /// picker's key status away again.
  func rekeyAfterEditorClose(refocus: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isVisible else { return }
      self.makeKey()
      refocus()
    }
  }
}
