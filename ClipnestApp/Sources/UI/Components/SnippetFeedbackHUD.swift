// SnippetFeedbackHUD.swift
//
// T-SNIPFB1: replaces the silent beep when a snippet expansion fails. A small,
// transient, non-activating panel near the pointer that says what happened and
// what to do. It never takes key/main status (so the user's text selection and
// focus stay in their app), ignores the mouse, and dismisses itself.

import AppKit
import ClipnestCore
import ClipnestViewModels

@MainActor
final class SnippetFeedbackHUD {
  static let displayDuration: TimeInterval = 3.5
  static let maxTextWidth: CGFloat = 320
  static let padding: CGFloat = 12
  static let cornerRadius: CGFloat = 10
  /// Gap between the pointer and the HUD.
  static let pointerOffset: CGFloat = 18

  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?
  private let beep: () -> Void
  private let pointerLocation: () -> NSPoint
  private let announce: (String) -> Void

  /// `beep` is the last resort when no screen is available to show on.
  init(
    beep: @escaping () -> Void,
    pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
    announce: @escaping (String) -> Void = { PickerAnnouncer.announce($0) }
  ) {
    self.beep = beep
    self.pointerLocation = pointerLocation
    self.announce = announce
  }

  /// Shows `message` for `displayDuration`, replacing any HUD already up.
  func show(message: String) {
    let origin = pointerLocation()
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(origin, $0.frame, false) })
        ?? NSScreen.main
    else {
      beep()
      return
    }
    let panel = self.panel ?? Self.makePanel()
    self.panel = panel
    Self.configure(panel, message: message)
    panel.setFrameOrigin(
      Self.frameOrigin(
        pointer: origin, size: panel.frame.size, screenVisibleFrame: screen.visibleFrame))
    panel.orderFrontRegardless()  // never makeKey: must not steal focus
    announce(message)

    hideWork?.cancel()
    let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: work)
  }

  /// Bottom-left origin placing the HUD just below-right of the pointer, shifted
  /// to stay fully inside `screenVisibleFrame` (flips above the pointer at the
  /// bottom edge). Pure so it can be unit tested.
  static func frameOrigin(pointer: NSPoint, size: NSSize, screenVisibleFrame: NSRect) -> NSPoint {
    var x = pointer.x + pointerOffset
    var y = pointer.y - pointerOffset - size.height
    if y < screenVisibleFrame.minY { y = pointer.y + pointerOffset }
    x = min(x, screenVisibleFrame.maxX - size.width)
    x = max(x, screenVisibleFrame.minX)
    y = min(y, screenVisibleFrame.maxY - size.height)
    y = max(y, screenVisibleFrame.minY)
    return NSPoint(x: x, y: y)
  }

  static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    // Every Clipnest window opts out of screen sharing (T-SHAREEXCL1).
    panel.excludeFromScreenSharing()
    return panel
  }

  private static func configure(_ panel: NSPanel, message: String) {
    let title = NSTextField(labelWithString: SnippetExpansionCopy.feedbackTitle)
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let body = NSTextField(wrappingLabelWithString: message)
    body.font = .systemFont(ofSize: NSFont.systemFontSize)
    body.preferredMaxLayoutWidth = maxTextWidth
    let stack = NSStackView(views: [title, body])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(
      top: padding, left: padding, bottom: padding, right: padding)

    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = cornerRadius
    background.layer?.masksToBounds = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      stack.topAnchor.constraint(equalTo: background.topAnchor),
      stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    panel.contentView = background
    let size = background.fittingSize
    panel.setContentSize(size)
  }
}
