// UpdateResultPanel.swift
//
// T-UPDALERT2: the NON-MODAL window that shows the "Check for Updates…" result.
//
// Why not `NSAlert.runModal()` (what 1.5.0–1.6.0 used): `runModal` parks the
// main thread inside a nested run loop until a button is clicked. Measured live
// with a full-screen app frontmost, the alert's window never became visible
// (activation of an `.accessory` app is refused; System Events listed 0 windows,
// CGWindowList showed no on-screen Clipnest window, `sample` showed the main
// thread in `-[NSAlert runModal]`) — so the whole app (hotkey, picker, menu)
// was blocked behind a window the user could not see, recoverable only by
// killing the process. A non-modal panel cannot wedge the app: if it ever lands
// off-screen, everything else keeps working and a second "Check for Updates…"
// simply raises it again.
//
// Visibility follows the picker/HUD recipe, which is proven over full-screen
// apps: a `.nonactivatingPanel` (no app activation needed, so no `.regular`
// policy flip, no Dock icon, no Space switch), `.canJoinAllSpaces` +
// `.fullScreenAuxiliary`, a high window level, `orderFrontRegardless()`.

import AppKit
import ClipnestViewModels

/// What a button in the result panel does. Kept separate from AppKit so the
/// mapping is unit-testable.
enum UpdateResultAction: Equatable {
  case update
  case dismiss
}

@MainActor
final class UpdateResultPanel: NSPanel {
  static let panelWidth: CGFloat = 380
  static let padding: CGFloat = 20
  static let iconSize: CGFloat = 48
  static let titleFontExtraSize: CGFloat = 2
  static let buttonSpacing: CGFloat = 8
  static let textSpacing: CGFloat = 6
  static let iconTextSpacing: CGFloat = 14
  static let contentButtonSpacing: CGFloat = 18
  /// Vertical placement: fraction of the visible frame height (from the
  /// bottom) at which the panel is centred — slightly above middle.
  static let verticalPlacement: CGFloat = 0.6
  static let updateButtonTitle = "Update"
  static let laterButtonTitle = "Later"
  static let okButtonTitle = "OK"
  /// Above normal windows and over full-screen apps, like the picker panel.
  static let windowLevel: NSWindow.Level = .popUpMenu
  static let spaceBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

  static let defaultKeyEquivalent = "\r"
  private static let returnKeyCode: UInt16 = 36
  private static let keypadEnterKeyCode: UInt16 = 76
  private static let escapeKeyCode: UInt16 = 53

  /// The one panel on screen (single instance); cleared when it closes.
  private(set) static var current: UpdateResultPanel?

  private let onUpdate: () -> Void
  private(set) var defaultButton: NSButton?
  private(set) var cancelButton: NSButton?
  private var buttonActions: [UpdateResultAction] = []
  private let feedback: UpdateCheckFeedback

  /// Button titles in display order (primary first), per the feedback.
  static func buttonTitles(for feedback: UpdateCheckFeedback) -> [String] {
    feedback.offersUpdate ? [updateButtonTitle, laterButtonTitle] : [okButtonTitle]
  }

  /// Button actions in display order, parallel to `buttonTitles(for:)`.
  static func buttonActions(for feedback: UpdateCheckFeedback) -> [UpdateResultAction] {
    feedback.offersUpdate ? [.update, .dismiss] : [.dismiss]
  }

  /// Shows the result, or raises the existing panel if one is already up.
  @discardableResult
  static func present(
    feedback: UpdateCheckFeedback, onUpdate: @escaping () -> Void
  ) -> UpdateResultPanel {
    if let existing = current {
      if existing.feedback == feedback {
        existing.raise()
        return existing
      }
      // Stale content (e.g. a newer check result): replace, don't show old.
      existing.close()
    }
    let panel = UpdateResultPanel(feedback: feedback, onUpdate: onUpdate)
    current = panel
    panel.raise()
    panel.announce()
    return panel
  }

  init(feedback: UpdateCheckFeedback, onUpdate: @escaping () -> Void) {
    self.onUpdate = onUpdate
    self.feedback = feedback
    super.init(
      contentRect: .zero,
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered, defer: true)
    isReleasedWhenClosed = false
    title = "Clipnest"
    level = Self.windowLevel
    collectionBehavior = Self.spaceBehavior
    // The default `hidesOnDeactivate` is true for panels; the app is never
    // active here, so it would hide the panel immediately.
    hidesOnDeactivate = false
    isMovableByWindowBackground = true
    contentView = buildContent(feedback: feedback)
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: self, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        if UpdateResultPanel.current === self { UpdateResultPanel.current = nil }
      }
    }
  }

  override var canBecomeKey: Bool { true }

  /// Centres on the screen under the mouse (the user's current Space) and
  /// shows without needing app activation.
  func raise() {
    let screen =
      NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      let size = frame.size
      setFrameOrigin(
        NSPoint(
          x: frame.midX - self.frame.width / 2,
          y: frame.minY + size.height * Self.verticalPlacement - self.frame.height / 2))
    }
    orderFrontRegardless()
    makeKey()
  }

  /// VoiceOver: a non-activating panel gets no automatic announcement (the old
  /// NSAlert activated the app), so announce the result explicitly.
  func announce() {
    NSAccessibility.post(
      element: self, notification: .windowCreated)
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: "\(feedback.title). \(feedback.message)",
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  /// Runs the action for `title` and closes the panel.
  func perform(_ action: UpdateResultAction) {
    close()
    if action == .update { onUpdate() }
  }

  /// Return / keypad Enter = default button, Esc = cancel — handled here too
  /// because the app is not active, so button key equivalents alone are not
  /// guaranteed to fire.
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case Self.returnKeyCode, Self.keypadEnterKeyCode:
      defaultButton?.performClick(nil)
    case Self.escapeKeyCode:
      cancelOperation(nil)
    default:
      super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    // Esc maps to the secondary button ("Later") or the only one ("OK"):
    // never to "Update".
    perform(.dismiss)
  }

  private func buildContent(feedback: UpdateCheckFeedback) -> NSView {
    let titleLabel = NSTextField(labelWithString: feedback.title)
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + Self.titleFontExtraSize)
    let body = NSTextField(wrappingLabelWithString: feedback.message)
    body.font = .systemFont(ofSize: NSFont.systemFontSize)
    body.preferredMaxLayoutWidth = Self.panelWidth - Self.padding * 2

    let titles = Self.buttonTitles(for: feedback)
    let actions = Self.buttonActions(for: feedback)
    buttonActions = actions
    let buttons: [NSButton] = titles.enumerated().map { index, title in
      let button = NSButton(title: title, target: self, action: #selector(buttonClicked(_:)))
      button.bezelStyle = .rounded
      button.tag = index
      return button
    }
    defaultButton = buttons.first
    defaultButton?.keyEquivalent = Self.defaultKeyEquivalent
    cancelButton = buttons.count > 1 ? buttons.last : buttons.first
    // Buttons right-aligned, primary rightmost (macOS convention).
    let buttonRow = NSStackView(views: Array(buttons.reversed()))
    buttonRow.orientation = .horizontal
    buttonRow.spacing = Self.buttonSpacing

    let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
    icon.setAccessibilityElement(false)  // decorative
    icon.widthAnchor.constraint(equalToConstant: Self.iconSize).isActive = true
    icon.heightAnchor.constraint(equalToConstant: Self.iconSize).isActive = true

    let text = NSStackView(views: [titleLabel, body])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = Self.textSpacing
    let top = NSStackView(views: [icon, text])
    top.orientation = .horizontal
    top.alignment = .top
    top.spacing = Self.iconTextSpacing

    let rootStack = NSStackView(views: [top, buttonRow])
    rootStack.orientation = .vertical
    rootStack.alignment = .trailing
    rootStack.spacing = Self.contentButtonSpacing
    rootStack.edgeInsets = NSEdgeInsets(
      top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
    rootStack.widthAnchor.constraint(equalToConstant: Self.panelWidth).isActive = true
    top.setHuggingPriority(.defaultLow, for: .horizontal)
    rootStack.layoutSubtreeIfNeeded()
    return rootStack
  }

  @objc private func buttonClicked(_ sender: NSButton) {
    guard buttonActions.indices.contains(sender.tag) else { return }
    perform(buttonActions[sender.tag])
  }
}
