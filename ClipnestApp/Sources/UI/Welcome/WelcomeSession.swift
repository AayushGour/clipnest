// WelcomeSession.swift
//
// T-WELCOME1: macOS glue behind the welcome window. All step logic and copy
// live in `WelcomeViewModel` / `WelcomeCopy` (ClipnestViewModels, shared with
// the Linux GTK window); this type only owns what is macOS-specific: reading
// the live KeyboardShortcuts binding, the Accessibility trust state (polled
// every second while the window is visible, only transitions announced), the
// "try it" hint timer, and the permission/Settings actions.

import AppKit
import ClipnestViewModels
import Combine
import KeyboardShortcuts

@MainActor
final class WelcomeSession: ObservableObject {
  let viewModel: WelcomeViewModel
  @Published private(set) var accessibilityState: WelcomeAccessibilityPresentation.State

  private let settings: SettingsStore
  private let isWindowVisible: () -> Bool
  private var hasPressedAllow: Bool
  private var pollTimer: Timer?
  private var hintTimer: Timer?
  private var cancellables: Set<AnyCancellable> = []

  /// Poll cadence for the Accessibility status (design.md: every 1 s).
  private static let pollInterval: TimeInterval = 1

  init(settings: SettingsStore, isWindowVisible: @escaping () -> Bool) {
    self.settings = settings
    self.isWindowVisible = isWindowVisible
    // `hasRequestedAccessibility` is set when the Allow button is pressed, so
    // a returning session (reopened via "Getting Started…") starts in the
    // "waiting" state if the user already asked and still has not granted.
    let pressed = settings.hasRequestedAccessibility
    self.hasPressedAllow = pressed
    let state = WelcomeAccessibilityPresentation.state(
      isGranted: PermissionsManager.isGranted, hasPressedAllow: pressed)
    self.accessibilityState = state
    self.viewModel = WelcomeViewModel(
      platform: .macOS, hotkey: Self.currentHotkey(), isPermissionComplete: state == .allowed)

    viewModel.$activeStep
      .removeDuplicates()
      .sink { [weak self] step in
        MainActor.assumeIsolated { self?.activeStepChanged(to: step) }
      }
      .store(in: &cancellables)
  }

  // MARK: Lifecycle

  func start() {
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.pollTick() }
    }
    activeStepChanged(to: viewModel.activeStep)
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
    hintTimer?.invalidate()
    hintTimer = nil
  }

  /// Window became key: the user may have rebound the hotkey or returned
  /// from System Settings.
  func windowDidBecomeKey() {
    viewModel.updateHotkey(Self.currentHotkey())
    refreshAccessibility()
  }

  private func pollTick() {
    // Paused while the window is not visible (minimized / fully covered).
    guard isWindowVisible() else { return }
    refreshAccessibility()
  }

  private func refreshAccessibility() {
    let state = WelcomeAccessibilityPresentation.state(
      isGranted: PermissionsManager.isGranted, hasPressedAllow: hasPressedAllow)
    if state != accessibilityState { accessibilityState = state }
    viewModel.updatePermission(
      isComplete: state == .allowed,
      announcement: WelcomeAccessibilityPresentation.allowedAnnouncement)
  }

  private func activeStepChanged(to step: WelcomeStep) {
    hintTimer?.invalidate()
    hintTimer = nil
    guard step == .tryIt, !viewModel.hasDetectedHotkey else { return }
    hintTimer = Timer.scheduledTimer(
      withTimeInterval: TimeInterval(WelcomeCopy.tryItHintDelaySeconds), repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.viewModel.tryItHintTimedOut() }
    }
  }

  // MARK: Actions

  /// Step 1's button: first press raises the system prompt, later presses
  /// (state `.awaitingUser`) open the Accessibility pane.
  func performAccessibilityAction() {
    switch accessibilityState {
    case .notAllowed:
      hasPressedAllow = true
      settings.hasRequestedAccessibility = true
      PermissionsManager.requestAccess()
      refreshAccessibility()
    case .awaitingUser:
      PermissionsManager.openAccessibilitySettings()
    case .allowed:
      break
    }
  }

  /// "Change in Settings…". `openSettings` is SwiftUI's
  /// `@Environment(\.openSettings)` action, which only a `View` can read, so
  /// `WelcomeView` passes it in (same pattern as `PickerView`). The tab is
  /// requested BEFORE opening so a cold open (Settings window not yet created)
  /// still lands on it when `SettingsView` first appears; warm opens pick it
  /// up through `onChange`.
  func openShortcutsSettings(using openSettings: () -> Void) {
    SettingsNavigator.shared.requestedTab = .shortcuts
    openSettings()
    SettingsFocusCoordinator.focusAfterOpening()
  }

  // MARK: Hotkey

  private static let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

  /// The live `togglePicker` binding as key caps. The key label is the
  /// library's own rendering minus the modifier glyphs, so special keys
  /// (arrows, F-keys, space) read exactly as in the Shortcuts tab.
  static func currentHotkey() -> WelcomeHotkey {
    guard let shortcut = KeyboardShortcuts.getShortcut(for: .togglePicker) else { return .unbound }
    let key = String(shortcut.description.filter { !modifierGlyphs.contains($0) })
    return .macOS(
      command: shortcut.modifiers.contains(.command),
      option: shortcut.modifiers.contains(.option),
      control: shortcut.modifiers.contains(.control),
      shift: shortcut.modifiers.contains(.shift),
      key: key)
  }
}
