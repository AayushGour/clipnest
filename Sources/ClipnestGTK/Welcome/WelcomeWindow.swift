// WelcomeWindow.swift
//
// T-WELCOME1-LX: the Linux first-run welcome window (design.md "Welcome
// window (T-WELCOME0)"), replacing the one-off `AutoPasteStartupPrompt`. One
// non-modal GtkWindow with two stacked step rows (the current one
// expanded), driven by the shared `WelcomeViewModel` (`ClipnestViewModels`),
// so state, copy and the Continue/Skip rules are identical to macOS.
//
// OBSERVATION: GTK has no SwiftUI/Combine binding, and the Linux
// `ObservableObject` stand-in fires `objectWillChange` BEFORE a mutation.
// Instead of subscribing, every mutation goes through this class
// (`primaryTapped`, `applyGrantOutcome`, `setExtensionStatus`, ...) which
// calls `render()` straight after it, so the view can never lag the model.
//
// BOUNDARIES: `ClipnestGTK` cannot import `ClipnestLinuxAppKit`, so the
// pkexec grant, the GNOME-extension actions and the Settings opener arrive as
// closures in `Configuration`, the same seam the old prompt used.
//
// USE-AFTER-FREE GUARD (kept from the old prompt): `pkexec` blocks on the
// user's polkit answer, which can arrive long after the window was closed.
// `isDismissed` is set on `close-request` and re-checked before any widget
// pointer is touched from the grant completion (or the hint timer).
//
// LIFETIME: every widget handle is a plain `OpaquePointer`, valid until GTK
// destroys the window on close (default close-request handling; this window
// is rebuilt on each "Getting Started…", unlike the hide-on-close Settings
// window). The owner holds the instance only to route status/picker events.
import CGtk4
import ClipnestViewModels
import Foundation

public final class WelcomeWindow: @unchecked Sendable {
  public struct Configuration {
    public var keyboardAccess: WelcomeKeyboardAccess
    public var extensionStatus: GnomeExtensionStatus
    /// Live binding, re-read when the window becomes active.
    public var readHotkey: () -> WelcomeHotkey
    /// Same shape as `SettingsWindow.requestUInputGrant`: the real caller is
    /// `GrantInputHelperClient.requestGrant` (`pkexec clipnest-grant-input`).
    public var requestUInputGrant: (_ completion: @escaping UInputGrantCompletion) -> Void
    public var extensionAction: (WelcomeGnomeExtensionPresentation.Action) -> Void
    /// Re-query the extension status (fired when the window becomes active).
    public var refreshExtensionStatus: () -> Void
    public var openShortcutsSettings: () -> Void
    public var onClosed: () -> Void

    public init(
      keyboardAccess: WelcomeKeyboardAccess,
      extensionStatus: GnomeExtensionStatus,
      readHotkey: @escaping () -> WelcomeHotkey,
      requestUInputGrant: @escaping (_ completion: @escaping UInputGrantCompletion) -> Void,
      extensionAction: @escaping (WelcomeGnomeExtensionPresentation.Action) -> Void,
      refreshExtensionStatus: @escaping () -> Void,
      openShortcutsSettings: @escaping () -> Void,
      onClosed: @escaping () -> Void
    ) {
      self.keyboardAccess = keyboardAccess
      self.extensionStatus = extensionStatus
      self.readHotkey = readHotkey
      self.requestUInputGrant = requestUInputGrant
      self.extensionAction = extensionAction
      self.refreshExtensionStatus = refreshExtensionStatus
      self.openShortcutsSettings = openShortcutsSettings
      self.onClosed = onClosed
    }
  }

  static let windowWidth: Int32 = 520
  /// Spec (design.md): ~420 pt tall. Header + footer + margins take ~140 of
  /// it, the rest is the scrolling step list.
  static let windowHeight: Int32 = 420
  static let stepListHeight: Int32 = 270
  static let margin: Int32 = 16
  static let spacing: Int32 = 10
  static let rowSpacing: Int32 = 4
  static let rowMargin: Int32 = 10
  static let wrapWidthChars: Int32 = 54
  static let iconPixelSize: Int32 = 48
  static let iconName = "app.clipnest.Clipnest"
  static let keyCapPadding: Int32 = 6

  let window: OpaquePointer
  let configuration: Configuration
  let viewModel: WelcomeViewModel
  var permission: WelcomeLinuxPermission

  /// See this file's "USE-AFTER-FREE GUARD" note.
  private(set) var isDismissed = false
  var hasPresented = false
  var lastFocusedStep: WelcomeStep?

  var rows: [WelcomeStep: StepRowWidgets] = [:]
  var primaryButton: OpaquePointer!
  var skipButton: OpaquePointer!
  var permissionStep: PermissionStepWidgets!
  var tryItStep: TryItStepWidgets!
  var renderedHotkey: WelcomeHotkey?
  var hintTask: Task<Void, Never>?
  var stepScroller: OpaquePointer?
  var renderedActiveStep: WelcomeStep?
  /// The widget `render()` last gave focus to (see `refocusIfNeeded`).
  var focusedWidget: OpaquePointer?

  @MainActor
  public init(configuration: Configuration) {
    self.configuration = configuration
    let permission = WelcomeLinuxPermission(
      keyboard: configuration.keyboardAccess, extensionStatus: configuration.extensionStatus)
    self.permission = permission
    viewModel = WelcomeViewModel(
      platform: .linux, hotkey: configuration.readHotkey(),
      isPermissionComplete: permission.isComplete)
    viewModel.setHotkeyPendingSetup(permission.isHotkeyPendingSetup)
    window = gtk_window_new()
    buildWindow()
    render()
  }

  // MARK: - Public

  /// Shows (or raises) the window.
  @MainActor
  public func present() {
    guard !isDismissed else { return }
    gtk_window_present(window)
    // Initial focus only; re-raising must not steal focus from what the user
    // was interacting with.
    if !hasPresented {
      hasPresented = true
      lastFocusedStep = viewModel.activeStep
      let target = focusWidget
      focusedWidget = target
      gtk_window_set_focus(window, target)
    }
  }

  /// Step 1's own action while permission is missing (never Skip), else the
  /// footer primary button. Mirrors `WelcomeViewModel.focusTarget`.
  @MainActor
  var focusWidget: OpaquePointer {
    let keyboardAction =
      permission.keyboard.buttonTitle != nil && permission.keyboard.isButtonEnabled
    let extensionAction = permission.extensionContent.action != nil
    let target = viewModel.focusTarget(permissionActionAvailable: keyboardAction || extensionAction)
    guard target == .permissionAction else { return primaryButton }
    return keyboardAction ? permissionStep.keyboard.button : permissionStep.extensionRow.button
  }

  public var isOpen: Bool { !isDismissed }

  /// Feed from `LinuxAppEnvironment.onGnomeExtensionStatusChanged`.
  @MainActor
  public func setExtensionStatus(_ status: GnomeExtensionStatus) {
    guard !isDismissed, status != permission.extensionStatus else { return }
    permission.extensionStatus = status
    render()
    if status != .checking {
      announce(WelcomeGnomeExtensionPresentation.content(for: status).statusText)
    }
  }

  /// Feed from the picker-shown event (hotkey, tray, D-Bus).
  @MainActor
  public func pickerDidShow() {
    guard !isDismissed else { return }
    viewModel.pickerDidShow()
    render()
  }

  /// The user's current binding, as the welcome window shows it.
  public static func currentHotkey() -> WelcomeHotkey {
    GlobalHotkeyAccelerator.current(.togglePicker).map(WelcomeHotkey.gnomeAccelerator) ?? .unbound
  }

  // MARK: - Actions

  @MainActor
  func primaryTapped() { navigate(viewModel.continueTapped()) }

  @MainActor
  func skipTapped() { navigate(viewModel.skipTapped()) }

  @MainActor
  private func navigate(_ result: WelcomeNavigation) {
    switch result {
    case .advanced: render()
    case .close: gtk_window_close(window)
    }
  }

  @MainActor
  func grantTapped() {
    guard permission.keyboard.grantStarted() else { return }
    render()
    configuration.requestUInputGrant { outcome in
      Task { @MainActor [weak self] in
        // Re-checked here, not just at click time: see "USE-AFTER-FREE GUARD".
        guard let self, !self.isDismissed else { return }
        self.applyGrantOutcome(outcome)
      }
    }
  }

  @MainActor
  private func applyGrantOutcome(_ outcome: UInputGrantOutcome) {
    switch outcome {
    case .succeeded(let message):
      permission.keyboard.grantFinished(succeeded: true, message: message)
    case .failed(let message): permission.keyboard.grantFinished(succeeded: false, message: message)
    }
    render()
    if let text = permission.keyboard.statusText { announce(text) }
  }

  @MainActor
  func extensionActionTapped(_ action: WelcomeGnomeExtensionPresentation.Action) {
    configuration.extensionAction(action)
  }

  @MainActor
  func changeInSettingsTapped() { configuration.openShortcutsSettings() }

  /// `notify::is-active`: the user may have rebound the hotkey in Settings or
  /// fixed the extension in the Extensions app while this window was behind.
  @MainActor
  func windowActiveChanged() {
    guard !isDismissed, gtk_window_is_active(window) != 0 else { return }
    viewModel.updateHotkey(configuration.readHotkey())
    switch permission.extensionStatus {
    case .disabledByUser, .userExtensionsDisabled, .failed:
      configuration.refreshExtensionStatus()
    case .checking, .unsupportedDesktop, .active, .installedNeedsRelogin:
      break
    }
    render()
  }

  /// `GtkWindow::close-request`. Returning 0 lets GTK destroy the window.
  @MainActor
  func closeRequested() -> Int32 {
    guard !isDismissed else { return 0 }
    isDismissed = true
    hintTask?.cancel()
    hintTask = nil
    configuration.onClosed()
    return 0
  }

  @MainActor
  func keyPressed(keyval: UInt32, state: UInt32) -> Int32 {
    guard let action = WelcomeKeyAction.action(keyval: keyval, state: state) else { return 0 }
    switch action {
    case .close:
      gtk_window_close(window)
      return 1
    }
  }

  @MainActor
  func announce(_ message: String) {
    GTKAccessibility.announce(window, message)
  }

  @MainActor
  func startHintTimerIfNeeded() {
    guard viewModel.activeStep == .tryIt, hintTask == nil, !viewModel.showsTryItHint,
      !viewModel.hasDetectedHotkey
    else { return }
    let delay = UInt64(WelcomeCopy.tryItHintDelaySeconds) * 1_000_000_000
    hintTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard let self, !Task.isCancelled, !self.isDismissed else { return }
      self.viewModel.tryItHintTimedOut()
      self.render()
    }
  }
}
