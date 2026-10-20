// WelcomeWindowController.swift
//
// T-WELCOME1: owns the one welcome `NSWindow`. Fixed 520x420, non-resizable,
// normal level, non-modal, centered on the screen under the pointer.
//
// Activation: Clipnest is an `.accessory` app, so a window will not come to
// front without the same `.regular` dance Settings uses. That is NOT
// re-implemented here: `SettingsFocusCoordinator.activator` (a shared
// `SettingsActivator`) is reused, and it restores `.accessory` only after the
// LAST observed window (welcome and/or Settings) closes.
//
// "Seen" is recorded at present time by `WelcomeGate` (never on close), so
// every close route — Done, Skip, Esc, ⌘W, titlebar X, Quit, force-quit —
// is already covered; this controller only tears the window down.

import AppKit
import ClipnestViewModels
import Combine
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
  private var window: WelcomeWindow?
  private var session: WelcomeSession?
  private var cancellables: Set<AnyCancellable> = []
  private let environment: AppEnvironment

  init(environment: AppEnvironment) {
    self.environment = environment
  }

  var isFrontmost: Bool { window?.isKeyWindow == true }

  /// Presents the window, or brings the existing one to front. Never touches
  /// the seen flag.
  func show() {
    if let window {
      SettingsFocusCoordinator.activator.activate(observing: window)
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
      return
    }

    let window = WelcomeWindow(
      contentRect: NSRect(origin: .zero, size: WelcomeView.windowSize),
      styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = WelcomeCopy.windowTitle
    window.isReleasedWhenClosed = false
    window.level = .normal
    window.delegate = self
    self.window = window

    let session = WelcomeSession(
      settings: environment.settingsStore,
      isWindowVisible: { [weak window] in window?.occlusionState.contains(.visible) ?? false })
    self.session = session

    let view = WelcomeView(
      session: session, viewModel: session.viewModel,
      onClose: { [weak window] in window?.performClose(nil) })
    window.contentView = NSHostingView(rootView: view)
    window.setContentSize(WelcomeView.windowSize)
    Self.center(window)

    // Step 3: the picker became visible (menu item or hotkey).
    environment.onPickerShown = { [weak session] in session?.viewModel.pickerDidShow() }
    // Never paste a test pick into the welcome window itself.
    environment.isOwnWindowFrontmost = { [weak self] in self?.isFrontmost ?? false }

    session.viewModel.$announcement
      .compactMap { $0 }
      .sink { [weak self] text in
        MainActor.assumeIsolated { self?.announce(text) }
      }
      .store(in: &cancellables)

    session.start()
    SettingsFocusCoordinator.activator.activate(observing: window)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  // MARK: NSWindowDelegate

  func windowDidBecomeKey(_ notification: Notification) {
    session?.windowDidBecomeKey()
  }

  func windowWillClose(_ notification: Notification) {
    session?.stop()
    session = nil
    cancellables.removeAll()
    environment.onPickerShown = nil
    environment.isOwnWindowFrontmost = { false }
    window?.delegate = nil
    window = nil
  }

  // MARK: Helpers

  private func announce(_ text: String) {
    guard let window else { return }
    NSAccessibility.post(
      element: window, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    // Next turn: clearing synchronously would re-enter the sink that is
    // delivering this value.
    Task { @MainActor [weak self] in self?.session?.viewModel.clearAnnouncement() }
  }

  /// Centers on the screen containing the pointer (falls back to main).
  private static func center(_ window: NSWindow) {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else {
      window.center()
      return
    }
    let size = window.frame.size
    window.setFrameOrigin(
      NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
  }
}

/// `Esc` and `⌘W` close the window even though an accessory app has no
/// "Close" menu item to carry the key equivalent.
final class WelcomeWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.charactersIgnoringModifiers == "w" {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
