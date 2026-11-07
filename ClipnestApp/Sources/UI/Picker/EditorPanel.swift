// EditorPanel.swift
//
// T-EDIT19/T-EDIT20: the shared window chrome of the two editors opened from
// the picker — `SnippetEditorWindow` and `ItemEditorWindow`.
//
// Both editors are titled, NON-ACTIVATING panels, for the same reason the
// picker itself is (see `PickerPanel`): Clipnest must never become the
// frontmost app while the picker is in use. The picker's paste path records
// the user's app when it opens and, right before synthesizing ⌘V, verifies
// that app is still frontmost (`Paster`, H-1). Root causes, confirmed with
// focus traces on macOS 26 (2026-11-07):
//
//  - The item editor called `NSApp.activate()`, so Clipnest stayed frontmost
//    after it closed and the next paste failed with
//    `targetNoLongerFrontmost` (the ding the user heard).
//  - The snippet editor flipped the policy `.accessory`→`.regular` to
//    activate. Flipping back on close deactivates Clipnest asynchronously;
//    `NSApplicationDidResignActive` landed ~16 ms AFTER the picker was
//    re-keyed and took its key status away, leaving a visible picker that
//    ignored the keyboard.
//
// A non-activating panel can still become key and take typed input (marked
// text/IME, Tab loop, Esc, key equivalents) while the user's app stays
// frontmost — the picker's search field relies on exactly that. So there is no
// activation to undo on close: re-keying the picker (`rekeyAfterEditorClose`)
// is all that's needed, and a later paste still reaches the user's app.

import AppKit

/// Base class for the picker's editor popups: a titled, closable,
/// non-activating floating panel that reports its close exactly once and is
/// reused across `present` calls.
@MainActor
class EditorPanel: NSPanel, NSWindowDelegate {
  private static let defaultSize = NSSize(width: 380, height: 460)

  /// Fires once, on the next close (Save, Cancel, Esc, red traffic light, ⌘W).
  private var onClose: (() -> Void)?

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    // Panels hide when their app deactivates by default; Clipnest is never
    // active here, and the user may click into another app mid-edit.
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    // Editors show (and are prefilled from) clipboard content, which may be a
    // secret — keep them out of screen sharing like the picker.
    excludeFromScreenSharing()
    delegate = self
    // The editors' controls are AppKit views (see EditorKeyboardControls.swift);
    // let AppKit rebuild the Tab loop in visual order whenever layout changes.
    autorecalculatesKeyViewLoop = true
  }

  @available(*, unavailable, message: "EditorPanel does not support NSCoding")
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for EditorPanel")
  }

  override var canBecomeKey: Bool { true }

  /// Installs `content`, lays the panel out beside `pickerPanel` (centered
  /// when it's `nil`/hidden), and makes it key WITHOUT activating Clipnest.
  func present(content: NSView, pickerPanel: PickerPanel?, onClose: @escaping () -> Void) {
    self.onClose = onClose
    contentView = content
    positionRelativeToPicker(pickerPanel)
    bringToFront()
  }

  /// Raises the panel and makes it key. Never `makeKeyAndOrderFront` /
  /// `NSApp.activate` — both would activate Clipnest (see the file comment).
  func bringToFront() {
    orderFrontRegardless()
    makeKey()
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
    onClose = nil
  }
}
