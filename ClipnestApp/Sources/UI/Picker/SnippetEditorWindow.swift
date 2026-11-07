// SnippetEditorWindow.swift
//
// T23 fix round, item 1 (real bug fix): the snippet create/edit form was
// originally presented as a SwiftUI `.sheet()` attached to `PickerPanel` —
// but `PickerPanel` is a `.nonactivatingPanel` whose owning app deliberately
// never activates (so the picker itself never steals focus from the app the
// user was in). A `.sheet()` attached to a window that can never truly
// activate inherits that same limitation: the title/body/tag fields could
// never actually receive typed input or ⌘V paste, because the window server
// never grants real key status to a sheet whose owning app isn't frontmost.
//
// The fix is a separate `EditorPanel` (titled, key-capable, but itself
// non-activating — see `EditorPanel.swift`): the form takes typed input
// while the user's app stays frontmost, so a later paste from the picker
// still reaches it (T-EDIT19 replaced the earlier activate-Clipnest
// approach, which left the picker dead to the keyboard after close).
//
// Window-positioning fix: originally opened screen-centered via `center()`,
// which could land it directly on top of `PickerPanel` (positioned at the
// cursor) since the two windows' frames are otherwise unrelated. It's now
// laid out as a side-by-side pair with the picker instead — see
// `positionRelativeToPicker(_:)` and `WindowPlacement.pairLayout`, which
// moves the *picker's* frame (not just the editor's) when needed so the
// two always end up with distinct left edges and, whenever the pair can
// fit the screen, zero overlap — not just "beside where the picker
// happens to already be."

import AppKit
import ClipnestViewModels
import SwiftUI

/// The snippet create/edit popup: an `EditorPanel` hosting `SnippetFormView`,
/// reused across every `show(mode:pickerPanel:tagError:expandShortcut:onSave:onClose:)`
/// call rather than recreated each time.
@MainActor
final class SnippetEditorWindow: EditorPanel {
  /// Shows the editor and makes it key without activating Clipnest (see
  /// `EditorPanel`).
  ///
  /// - Parameters:
  ///   - mode: Which form state to present — see `SnippetFormMode`.
  ///   - pickerPanel: The picker panel the editor is being opened from
  ///     (`AppEnvironment` owns/reaches both). When it's currently visible,
  ///     the editor + picker are laid out as a side-by-side pair (see
  ///     `positionRelativeToPicker(_:)`) instead of centering the editor —
  ///     this may **move the picker's frame** (never its size) to make
  ///     room. Pass `nil` (or a hidden panel) to fall back to centered
  ///     placement.
  ///   - tagError: Inline duplicate-tag check for the form (T-SNIPFB1); nil = OK.
  ///   - expandShortcut: Shown in the Tag helper text (T-SNIPFB1).
  ///   - onSave: Called with the trimmed title/body/keyword once the user
  ///     taps Save. The caller decides create vs. update (this type has no
  ///     opinion — it doesn't know about `SnippetStore`).
  ///   - onClose: Called exactly once, whenever this window closes for any
  ///     reason (Save, Cancel, Esc, the red traffic light, ⌘W).
  func show(
    mode: SnippetFormMode,
    pickerPanel: PickerPanel?,
    tagError: @escaping (_ tag: String) -> String?,
    expandShortcut: String,
    onSave: @escaping (_ title: String, _ body: String, _ keyword: String?) -> Void,
    onClose: @escaping () -> Void
  ) {
    title = SnippetEditStrings.title(isNew: mode.isNew)
    present(
      content: NSHostingView(
        rootView: SnippetFormView(
          mode: mode,
          tagError: tagError,
          expandShortcut: expandShortcut,
          onSave: { [weak self] title, body, keyword in
            onSave(title, body, keyword)
            self?.close()
          },
          onCancel: { [weak self] in
            self?.close()
          }
        )
      ),
      pickerPanel: pickerPanel,
      onClose: onClose
    )
  }
}
