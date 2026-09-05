import ClipnestCore
import ClipnestGTK
import ClipnestPlatformLinux
import Foundation

/// Owns process startup end-to-end, in the order this task's build steps
/// require:
/// 1. GTK init + the `@MainActor`/GLib bridge (`GTKMainActorBridge`) —
///    BEFORE anything else, since every step after this makes `@MainActor`
///    hops that silently never resume without it (see that type's doc
///    comment).
/// 2. Single-instance acquisition (`SingleInstance.acquire`) — before any
///    expensive work, so a second launch forwards its argv and exits
///    almost immediately rather than paying for a full composition-root
///    build it's about to throw away.
/// 3. The composition root (`LinuxAppEnvironment`), D-Bus control service,
///    Shell-extension client, tray, and hotkey backend — in that order,
///    since the control service and tray need `environment`'s methods to
///    route into, and the hotkey backend's choice depends on what the
///    Shell-extension client just negotiated.
///
/// `@MainActor`, matching `LinuxAppEnvironment` — everything here either
/// touches `@MainActor` state directly or hands work to a background
/// `Thread` (the various D-Bus receive loops) that reports back through a
/// `Task { @MainActor in ... }` hop, same discipline the rest of this
/// module follows throughout.
@MainActor
public enum LinuxAppLifecycle {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "LinuxAppLifecycle")

  private static let sessionBusAddressEnvironmentVariableName = "DBUS_SESSION_BUS_ADDRESS"
  private static let sessionBusConnectTimeout: Duration = .seconds(2)

  /// This app's own `app.clipnest.Control.Capabilities` — see
  /// `ClipnestControlCapability`'s doc comment. All three are always true
  /// today (nothing in `LinuxAppEnvironment`'s wiring is conditional), but
  /// kept as an explicit list (not a hardcoded literal at the one call
  /// site) so a future capability that IS conditional has an obvious place
  /// to compute itself.
  private static let controlCapabilities: [String] = [
    ClipnestControlCapability.picker, ClipnestControlCapability.snippetExpansion,
    ClipnestControlCapability.settings,
  ]

  /// The single named GSettings-floor keybinding segment this app installs
  /// (see `GSettingsKeybindingPath`'s doc comment on why it must be
  /// named, never `customN`).
  private static let toggleKeybindingSegment = "clipnest-toggle"
  private static let defaultToggleAccelerator = "<Super><Shift>v"

  /// Entry point called from `main.swift`. Never returns until the GTK
  /// main loop exits (`ClipnestGTKApplication.quitMainLoop()`, wired to
  /// the tray's Quit item) — matches every other GTK application's
  /// `main()`.
  public static func run(arguments: [String]) {
    ClipnestGTKApplication.initializeGTK()
    GTKMainActorBridge.install()

    let sessionBusAddress = ProcessInfo.processInfo.environment[
      sessionBusAddressEnvironmentVariableName]
    let instanceConnection = sessionBusAddress.flatMap {
      DBusConnection.connect(address: $0, timeout: sessionBusConnectTimeout)
    }

    let decision: SingleInstanceDecision =
      instanceConnection.map { SingleInstance.acquire(on: $0, timeout: .milliseconds(500)) }
      ?? .busUnavailable

    if decision == .forwardToRunningInstance {
      if let instanceConnection {
        SingleInstance.forwardArguments(Array(arguments.dropFirst()), on: instanceConnection)
      }
      logger.info("another Clipnest instance owns the bus name — forwarded argv and exiting")
      exit(0)
    }

    let controlConnection = decision == .becomePrimary ? instanceConnection : nil
    let initialCommand = LinuxAppCLI.parse(Array(arguments.dropFirst()))

    Task {
      await launch(
        sessionBusAddress: sessionBusAddress, controlConnection: controlConnection,
        initialCommand: initialCommand)
    }

    ClipnestGTKApplication.runMainLoop()
  }

  private static func launch(
    sessionBusAddress: String?, controlConnection: DBusConnection?,
    initialCommand: LinuxAppCLICommand
  ) async {
    let environment: LinuxAppEnvironment
    do {
      environment = try await LinuxAppEnvironment()
    } catch {
      logger.error("failed to initialize LinuxAppEnvironment: \(String(describing: error))")
      ClipnestGTKApplication.quitMainLoop()
      return
    }

    environment.startCapture()
    environment.startUpdateChecking()
    environment.enforceRetentionNow()

    switch initialCommand {
    case .togglePicker: environment.togglePicker()
    case .expandSnippet: environment.expandSnippet()
    case .none: break
    }

    guard let controlConnection, let sessionBusAddress else {
      logger.info(
        "no session bus reachable — running standalone with no D-Bus control surface, tray, or Shell-extension integration"
      )
      return
    }

    startControlService(on: controlConnection, environment: environment)

    let shellHelperClient = makeShellHelperClient(sessionBusAddress: sessionBusAddress)
    wireShellHelper(shellHelperClient, environment: environment)

    startTray(sessionBusAddress: sessionBusAddress, environment: environment)

    installHotkeys(
      sessionBusAddress: sessionBusAddress, shellHelperClient: shellHelperClient,
      environment: environment)
  }

  private static func startControlService(
    on connection: DBusConnection, environment: LinuxAppEnvironment
  ) {
    let service = ClipnestControlService(connection: connection, capabilities: controlCapabilities)
    service.onTogglePicker = { Task { @MainActor in environment.togglePicker() } }
    service.onShowPicker = { options in
      Task { @MainActor in
        let point = options.pointer.map { (x: Int($0.x), y: Int($0.y)) }
        environment.showPicker(at: point)
      }
    }
    service.onHidePicker = { Task { @MainActor in environment.hidePicker() } }
    service.onExpandSnippet = { Task { @MainActor in environment.expandSnippet() } }
    service.onOpenSettings = { Task { @MainActor in environment.openSettings() } }
    service.start()
  }

  private static func makeShellHelperClient(sessionBusAddress: String) -> ShellHelperClient? {
    guard
      let callConnection = DBusConnection.connect(
        address: sessionBusAddress, timeout: sessionBusConnectTimeout)
    else { return nil }
    let signalConnection = DBusConnection.connect(
      address: sessionBusAddress, timeout: sessionBusConnectTimeout)
    let client = ShellHelperClient(
      callConnection: callConnection, signalConnection: signalConnection)
    client.startWatching()
    client.refreshCapabilities()
    return client
  }

  private static func wireShellHelper(
    _ client: ShellHelperClient?, environment: LinuxAppEnvironment
  ) {
    guard let client else { return }
    client.onShortcutActivated = { action, options in
      Task { @MainActor in
        switch action {
        case ShellExtensionKeybindingSchema.expandSnippetKey: environment.expandSnippet()
        default:
          let point = options.pointer.map { (x: Int($0.x), y: Int($0.y)) }
          environment.showPicker(at: point)
        }
      }
    }
    // See `LinuxAppEnvironment.placeWindowHandler`'s doc comment /
    // `PickerWindow.swift`'s own: only the compositor (via this D-Bus
    // call) can actually move/raise/skip-taskbar a GTK4 window — flags
    // above + skip-taskbar match a transient popup picker, never sticky
    // (it should NOT survive a workspace switch).
    environment.placeWindowHandler = { windowToken, x, y in
      _ = client.placeWindow(
        windowToken: windowToken, x: Int32(x), y: Int32(y),
        flags: PlaceWindowFlag.above | PlaceWindowFlag.skipTaskbar)
    }
  }

  private static func startTray(sessionBusAddress: String, environment: LinuxAppEnvironment) {
    guard
      let ownConnection = DBusConnection.connect(
        address: sessionBusAddress, timeout: sessionBusConnectTimeout)
    else { return }
    let watchConnection = DBusConnection.connect(
      address: sessionBusAddress, timeout: sessionBusConnectTimeout)
    let tray = StatusNotifierTray(ownConnection: ownConnection, watchConnection: watchConnection)
    tray.onOpenClipnest = { Task { @MainActor in environment.togglePicker() } }
    tray.onOpenSettings = { Task { @MainActor in environment.openSettings() } }
    tray.onQuit = { Task { @MainActor in ClipnestGTKApplication.quitMainLoop() } }
    tray.start()
  }

  /// Priority chain (this task's build step 5): Shell-extension keybinding
  /// -> `XGrabKey` (blocked in this build — see `HotkeyBackend.xGrabKey`'s
  /// doc comment) -> `GlobalShortcuts` portal (dead on 22.04/24.04, kept
  /// for forward compatibility) -> the GSettings floor.
  private static func installHotkeys(
    sessionBusAddress: String, shellHelperClient: ShellHelperClient?,
    environment: LinuxAppEnvironment
  ) {
    let shellExtensionAvailable =
      shellHelperClient?.currentCapabilities.canDeliverShortcuts ?? false
    let portalAvailable: Bool
    if let probeConnection = DBusConnection.connect(
      address: sessionBusAddress, timeout: sessionBusConnectTimeout)
    {
      portalAvailable = GlobalShortcutsPortalClient.isAvailable(
        on: probeConnection, timeout: .milliseconds(500))
    } else {
      portalAvailable = false
    }

    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: shellExtensionAvailable,
      // See `HotkeyBackend.xGrabKey`'s doc comment: no `CXlib` dependency
      // is declared for this target, so this tier can never be attempted
      // from here.
      xGrabKeyAvailable: false, globalShortcutsPortalAvailable: portalAvailable)

    logger.info("hotkey backend resolved: \(String(describing: backend))")

    switch backend {
    case .shellExtensionKeybinding:
      // The extension reads `app.clipnest.Clipnest.Keybindings` itself
      // (`extension/src/core/keybindings.js`) and fires `ShortcutActivated`
      // — nothing further to install; `wireShellHelper` above already
      // routes that signal.
      break
    case .xGrabKey, .globalShortcutsPortal:
      // Neither can actually be reached in this build (see the doc
      // comments above) — fall through to the floor so a hotkey exists at
      // all rather than silently having none.
      installGSettingsFloor()
    case .gsettingsFloor:
      installGSettingsFloor()
    }
  }

  private static func installGSettingsFloor() {
    guard let executablePath = CommandLine.arguments.first else { return }
    let absolutePath =
      executablePath.hasPrefix("/")
      ? executablePath : FileManager.default.currentDirectoryPath + "/" + executablePath
    GSettingsCustomKeybinding.install(
      name: "Clipnest — Toggle Picker",
      command: "\(absolutePath) \(LinuxAppCLIFlag.togglePicker)",
      binding: defaultToggleAccelerator, segment: toggleKeybindingSegment)
  }
}
