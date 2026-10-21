import ClipnestGTK
import ClipnestViewModels

/// Owns the welcome window's lifecycle on Linux (T-WELCOME1-LX): decides when
/// to show it (`WelcomeGate`, once at launch), builds it with the real
/// pkexec / GNOME-extension / Settings seams, and forwards the two live
/// events it listens for (extension status, picker shown). "Getting
/// Started…" calls `show()`, which never touches the seen flag.
@MainActor
final class WelcomeCoordinator {
  private let environment: LinuxAppEnvironment
  private var window: WelcomeWindow?

  init(environment: LinuxAppEnvironment) {
    self.environment = environment
    environment.onGnomeExtensionStatusChanged = { [weak self] status in
      self?.window?.setExtensionStatus(status)
    }
    environment.onPickerShown = { [weak self] in self?.window?.pickerDidShow() }
  }

  /// Once per launch, after the store opened and the tray exists. A
  /// store-open failure never reaches this composition root (init throws), so
  /// `isSuppressed` is false here.
  func presentAtLaunchIfNeeded() {
    guard WelcomeGate.presentIfNeeded(settings: environment.settingsStore, isSuppressed: false)
    else { return }
    show()
  }

  /// Opens the window, or raises it when already open.
  func show() {
    if let window, window.isOpen {
      window.present()
      return
    }
    let uinput = UInputPermissionChecker.currentStatus()
    let keyboard = WelcomeKeyboardAccess(
      isAutoPasteAvailable: environment.eventSynthesizerKind != .clipboardOnly,
      isAlreadyInInputGroup: uinput.isInClipnestInputGroup || uinput.isUInputAccessible)
    let environment = self.environment
    // Step 2 shares Settings -> General's backend (the autostart .desktop
    // file). Pre-checked until the user has answered once, then the real state.
    let executablePath = OwnExecutablePath.resolve()
    let settings = environment.settingsStore
    let launchAtLogin = WelcomeLaunchAtLogin(
      isEnabled: { AutostartDesktopFile.isEnabled() },
      setEnabled: { try AutostartDesktopFile.setEnabled($0, executablePath: executablePath) },
      recordChoice: { settings.hasChosenLaunchAtLogin = true })
    let newWindow = WelcomeWindow(
      configuration: .init(
        keyboardAccess: keyboard,
        extensionStatus: environment.gnomeExtensionStatus,
        launchAtLogin: launchAtLogin,
        launchAtLoginPreChecked: settings.hasChosenLaunchAtLogin
          ? AutostartDesktopFile.isEnabled() : true,
        readHotkey: { WelcomeWindow.currentHotkey() },
        requestUInputGrant: { completion in
          GrantInputHelperClient.requestGrant(completion: completion)
        },
        extensionAction: { action in
          switch action {
          case .turnOn: environment.rerunGnomeExtensionSetup(turnOn: true)
          case .tryAgain: environment.rerunGnomeExtensionSetup()
          }
        },
        refreshExtensionStatus: { environment.rerunGnomeExtensionSetup(resetToChecking: false) },
        openShortcutsSettings: { environment.openSettings(tab: .shortcuts) },
        canLogOut: SessionLogoutClient.isSupported(),
        requestLogOut: { SessionLogoutClient.requestLogout() },
        onClosed: { [weak self] in self?.window = nil }))
    window = newWindow
    newWindow.present()
  }
}
