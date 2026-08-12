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
// The snippet editor is a fundamentally different UX moment from the picker
// itself: the user has explicitly clicked "+"/Edit (or a row's "Save as
// Snippet") to type into a form, so — unlike the picker, which must never
// steal focus — it's expected and safe for this window to properly activate
// Clipnest and become key/main, exactly the way any accessory-policy
// menu-bar utility's own "Preferences" window already would.
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
import SwiftUI

/// A real, standard, titled `NSWindow` (not a nonactivating panel) hosting
/// `SnippetFormView` — reused across every
/// `show(mode:pickerPanel:onSave:onClose:)` call rather than recreated each
/// time, mirroring `PickerPanel`'s long-lived-instance shape.
@MainActor
final class SnippetEditorWindow: NSWindow, NSWindowDelegate {
  private static let defaultSize = NSSize(width: 380, height: 460)

  /// Gap, in points, kept between the editor and the picker panel when
  /// placing the editor beside it — see `positionRelativeToPicker(_:)`.
  private static let pickerPlacementGap: CGFloat = 12

  /// Fires once, on the very next close — Save, Cancel, the red traffic
  /// light, or ⌘W all end up here via `windowWillClose(_:)` — so the
  /// composition root has one place to react to "the editor is gone now"
  /// regardless of which path triggered it (e.g. re-keying `PickerPanel`).
  private var onClose: (() -> Void)?

  /// The designated initializer (not `convenience`, and calling
  /// `super.init(...)` directly): declaring `required init?(coder:)` below
  /// means this subclass no longer automatically inherits `NSWindow`'s own
  /// `init(contentRect:styleMask:backing:defer:)` for a `convenience init`
  /// to delegate to via `self.init(...)` — same reasoning as `PickerPanel`'s
  /// identically-shaped initializer.
  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    isReleasedWhenClosed = false
    level = .floating
    delegate = self
  }

  /// Never used (no Interface Builder/NSCoding archiving anywhere in
  /// Clipnest) — required by `NSWindow`'s `NSCoding` conformance whenever a
  /// subclass adds its own designated initializer. See `PickerPanel`'s
  /// identical requirement/rationale.
  @available(*, unavailable, message: "SnippetEditorWindow does not support NSCoding")
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for SnippetEditorWindow")
  }

  /// Shows the editor, activating Clipnest and making this window key/main —
  /// see the file's doc comment for why that's both necessary and safe here,
  /// unlike the picker panel itself.
  ///
  /// - Parameters:
  ///   - mode: Which form state to present — see `SnippetFormMode`.
  ///   - pickerPanel: The picker panel the editor is being opened from
  ///     (`AppEnvironment` owns/reaches both). When it's currently visible,
  ///     the editor + picker are laid out as a side-by-side pair (see
  ///     `positionRelativeToPicker(_:)`) instead of centering the editor —
  ///     this may **move the picker's frame** (never its size) to make
  ///     room. Pass `nil` (or a hidden panel) to fall back to the original
  ///     centered placement — e.g. if the editor is ever opened from
  ///     somewhere other than the picker.
  ///   - onSave: Called with the trimmed title/body/keyword once the user
  ///     taps Save. The caller decides create vs. update (this type has no
  ///     opinion — it doesn't know about `SnippetStore`).
  ///   - onClose: Called exactly once, whenever this window closes for any
  ///     reason (see `onClose`'s doc comment).
  func show(
    mode: SnippetFormMode,
    pickerPanel: PickerPanel?,
    onSave: @escaping (_ title: String, _ body: String, _ keyword: String?) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.onClose = onClose
    title = mode.isNew ? "New Snippet" : "Edit Snippet"
    contentView = NSHostingView(
      rootView: SnippetFormView(
        mode: mode,
        onSave: { [weak self] title, body, keyword in
          onSave(title, body, keyword)
          self?.close()
        },
        onCancel: { [weak self] in
          self?.close()
        }
      )
    )
    positionRelativeToPicker(pickerPanel)
    // `activate()` (no `ignoringOtherApps:`) — the `ignoringOtherApps:`
    // overload is deprecated as of macOS 14, our exact deployment floor;
    // plain `activate()` is the current replacement and behaves
    // equivalently for a single-app-instance accessory app like Clipnest.
    NSApp.activate()
    makeKeyAndOrderFront(nil)
  }

  /// Lays the editor out beside `pickerPanel` as a side-by-side pair (see
  /// `WindowPlacement.pairLayout`) — picker on the left, editor to its
  /// right with a `pickerPlacementGap` gap, top-aligned, both clamped to
  /// stay fully on the picker's screen. **Moves `pickerPanel`'s frame**
  /// (shifting it left only as far as needed, never resizing it) when its
  /// current position doesn't leave room for the editor, guaranteeing
  /// distinct left edges and — whenever the pair can fit the screen's
  /// visible width — zero overlap between the two windows; a same-left-edge
  /// stacked fallback (e.g. "below/above") is deliberately never used, per
  /// the explicit requirement that the two windows must always read as
  /// side by side, not stacked. `pickerPanel`'s new position is left as-is
  /// once the editor closes — not restored, since it's a non-activating
  /// panel the user can freely reposition/reopen anyway.
  ///
  /// Falls back to the original centered placement whenever the picker
  /// isn't currently visible (nothing to avoid overlapping) — e.g.
  /// `pickerPanel` is `nil`, or its `screen` is `nil` because it isn't on
  /// screen. Doesn't change the editor's size — only `setFrameOrigin`,
  /// never `setFrame`.
  private func positionRelativeToPicker(_ pickerPanel: PickerPanel?) {
    guard let pickerPanel, pickerPanel.isVisible, let screen = pickerPanel.screen else {
      center()
      return
    }
    let (pickerOrigin, editorOrigin) = WindowPlacement.pairLayout(
      pickerFrame: pickerPanel.frame,
      editorSize: frame.size,
      screenVisibleFrame: screen.visibleFrame,
      gap: Self.pickerPlacementGap
    )
    pickerPanel.setFrameOrigin(pickerOrigin)
    setFrameOrigin(editorOrigin)
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
    onClose = nil
  }
}
