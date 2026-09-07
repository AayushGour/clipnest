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

  // MARK: - Process-lifetime ownership (T-LX1 fix, then generalized)
  //
  // `ClipnestControlService.start()`/`StatusNotifierTray.start()`/
  // `ATSPIFocusTracker.start()` all spawn a background receive-loop
  // `Thread { [weak self] in self?.receiveLoop() }`. That shape only works
  // if something ELSE holds a strong reference until the freshly spawned
  // thread's first access to `self` (after which `receiveLoop()`'s own
  // `while true` body keeps itself alive strongly for as long as it runs,
  // via the `self?.foo()` optional-chain's implicit strong temporary).
  //
  // T-LX1 found `startControlService` handing `ClipnestControlService` off
  // as a purely local `let` with no such owner: the instant that function
  // returned, ARC dropped its only strong reference — deterministically,
  // and almost always BEFORE the new OS thread was actually scheduled
  // (`Thread.start()`'s underlying `pthread_create` has real scheduling
  // latency; a function return does not). So `self` resolved to `nil`
  // inside the thread and `receiveLoop()` never ran a single iteration:
  // the service claimed `app.clipnest.Clipnest` (that happens earlier and
  // synchronously, via `SingleInstance.acquire` on the calling thread,
  // before this is even reached) but could never read, let alone answer,
  // one method call — exactly the observed symptom (`Ping`/`Introspect`
  // time out with zero reply, `clipnest-ctl toggle-picker` hangs forever
  // forwarding into the void).
  //
  // Independent review (post-fix) found the IDENTICAL shape, still
  // unowned, in two more places built the same session: `StatusNotifierTray`
  // (`startTray`'s `let tray = ...`) and `ShellHelperClient`
  // (`makeShellHelperClient`'s returned value, previously surviving only
  // by an ACCIDENTAL mutual-retain cycle through the closures
  // `wireShellHelper`/`installHotkeys` hand it — no deliberate owner of
  // its own). All four — plus `LinuxAppEnvironment` itself, whose
  // lifetime used to be purely incidental on whichever of these four
  // happened to still be retained — get one explicit, deliberate owner
  // here: this enum's own static state, which lives for the process's
  // whole life (same duration `installGSettingsFloor`'s one-shot side
  // effect already assumes). This is the same "retain via a real owner"
  // pattern the one case that already worked, `ATSPIFocusTracker`, relies
  // on (there, the `focusedObject: { focusTracker.currentFocusedObject() }`
  // closure captured by the long-lived `ATSPITextAccessor` is that owner).
  private static var environment: LinuxAppEnvironment?
  private static var controlService: ClipnestControlService?
  private static var shellHelperClient: ShellHelperClient?
  private static var tray: StatusNotifierTray?

  /// Entry point called from `main.swift`. Never returns until the GTK
  /// main loop exits (`ClipnestGTKApplication.quitMainLoop()`, wired to
  /// the tray's Quit item) — matches every other GTK application's
  /// `main()`.
  public static func run(arguments: [String]) {
    let commandArguments = Array(arguments.dropFirst())
    let earlyCommand = LinuxAppCLI.parse(commandArguments)

    // T-BB2 fix (black-box test, Ubuntu 22.04): `--version`/`--help` MUST
    // be handled before any single-instance/bus logic and before GTK even
    // initializes — print to stdout and exit(0), never launch a window,
    // never forward to a running instance. Previously neither flag was
    // recognized at all: with no instance running they fell through to a
    // full resident GUI launch (the tester had to `timeout`-kill it, exit
    // 124); with one running they silently forwarded and printed nothing.
    switch earlyCommand {
    case .version:
      print(LinuxAppEnvironment.installedVersion)
      exit(0)
    case .help:
      print(LinuxAppCLI.usageText)
      exit(0)
    case .togglePicker, .expandSnippet, .none:
      break
    }

    ClipnestGTKApplication.initializeGTK(
      programName: ClipnestControlName.programName,
      displayName: ClipnestControlName.displayName)
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
        SingleInstance.forwardArguments(commandArguments, on: instanceConnection)
      }
      logger.info("another Clipnest instance owns the bus name — forwarded argv and exiting")
      exit(0)
    }

    let controlConnection = decision == .becomePrimary ? instanceConnection : nil

    Task {
      await launch(
        sessionBusAddress: sessionBusAddress, controlConnection: controlConnection,
        initialCommand: earlyCommand)
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
    // Deliberate owner for the composition root's whole process lifetime —
    // see the "Process-lifetime ownership" doc comment above `environment`.
    Self.environment = environment

    environment.startCapture()
    environment.startUpdateChecking()
    environment.enforceRetentionNow()

    switch initialCommand {
    case .togglePicker: environment.togglePicker()
    case .expandSnippet: environment.expandSnippet()
    // Unreachable in practice: `run(arguments:)`'s early-exit guard above
    // handles `.version`/`.help` and `exit(0)`s before this async `launch`
    // is ever scheduled (see T-BB2's doc comment there). Kept here only
    // because `LinuxAppCLICommand`'s switch must stay exhaustive.
    case .version, .help, .none: break
    }

    guard let controlConnection, let sessionBusAddress else {
      logger.info(
        "no session bus reachable — running standalone with no D-Bus control surface, tray, or Shell-extension integration"
      )
      return
    }

    startControlService(on: controlConnection, environment: environment)

    let shellHelperClient = makeShellHelperClient(sessionBusAddress: sessionBusAddress)
    // See the "Process-lifetime ownership" doc comment above — this used
    // to survive only via an accidental retain cycle through the closures
    // wired below.
    Self.shellHelperClient = shellHelperClient
    wireShellHelper(shellHelperClient, environment: environment)

    startTray(sessionBusAddress: sessionBusAddress, environment: environment)

    installHotkeys(sessionBusAddress: sessionBusAddress, shellHelperClient: shellHelperClient)
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
    // Must happen — see `controlService`'s doc comment: without this, the
    // service (and its receive thread's only path to a live `self`) is
    // gone before the thread it just started ever gets scheduled.
    controlService = service
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
    // See the "Process-lifetime ownership" doc comment above `environment`
    // — without this, `tray`'s receive thread has the identical unowned-
    // weak-self shape T-LX1 fixed for `ClipnestControlService`.
    Self.tray = tray
  }

  /// Priority chain (this task's build step 5): Shell-extension keybinding
  /// -> `XGrabKey` (blocked in this build — see `HotkeyBackend.xGrabKey`'s
  /// doc comment) -> `GlobalShortcuts` portal (dead on 22.04/24.04, kept
  /// for forward compatibility) -> the GSettings floor.
  private static func installHotkeys(
    sessionBusAddress: String, shellHelperClient: ShellHelperClient?
  ) {
    let shellExtensionAvailable =
      shellHelperClient?.currentCapabilities.canDeliverShortcuts ?? false
    // See `HotkeyBackend.shellExtensionKeybinding`'s doc comment / this
    // task's audit: a stub extension whose service exports no D-Bus
    // methods at all still makes `Capabilities` advertise "hotkeys" —
    // grabbing the mutter keybinding is a real, independent side effect —
    // so that string is never trusted alone. Only skip the live probe
    // entirely when hotkeys weren't even claimed, to avoid a pointless
    // round trip.
    let shellExtensionLiveDispatchConfirmed =
      shellExtensionAvailable && (shellHelperClient?.probeLiveDispatch() ?? false)
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
      shellExtensionLiveDispatchConfirmed: shellExtensionLiveDispatchConfirmed,
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

  /// The `command` written here is executed later by gnome-settings-daemon,
  /// which inherits neither this process's `$PATH` resolution nor its working
  /// directory — see `OwnExecutablePath` for why `CommandLine.arguments.first`
  /// (used here previously) silently produced a non-existent `//clipnest` for
  /// the packaged bare-command launch this app actually ships as, disabling
  /// the universal hotkey floor.
  private static func installGSettingsFloor() {
    GSettingsCustomKeybinding.install(
      name: "Clipnest — Toggle Picker",
      command: "\(OwnExecutablePath.resolve()) \(LinuxAppCLIFlag.togglePicker)",
      binding: defaultToggleAccelerator, segment: toggleKeybindingSegment)
  }
}
