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

  // MARK: - T-P10I: live, retried hotkey-backend resolution
  //
  // `org.freedesktop.portal.GlobalShortcuts` availability barely ever
  // changes at runtime (tied to the GNOME Shell version, not anything this
  // app or the extension does) — probed once at startup in `installHotkeys`
  // and cached here so `reconcileHotkeyBackend` (which can now run many
  // times over a session, live, off `onCapabilitiesChanged`) never re-pays
  // that round trip.
  private static var cachedGlobalShortcutsPortalAvailable = false

  /// The backend `reconcileHotkeyBackend` last resolved and logged — kept
  /// only so a live change (the extension appearing, disappearing, or a
  /// delayed probe finally succeeding) is logged as a visible TRANSITION,
  /// not a repeat of the same steady-state line on every capability
  /// refresh.
  private static var lastResolvedHotkeyBackend: HotkeyBackend?

  /// The bounded retry schedule for `ShellHelperClient.probeLiveDispatch()`
  /// — see `retryLiveDispatchProbeIfNeeded`'s doc comment for the exact
  /// race this closes. Cumulative ~2s, comfortably above the ~1.5s
  /// worst-case propagation delay confirmed live against a real GNOME
  /// Shell (`packaging/linux/gnome-shell-test/README.md`'s "Findings"
  /// section). A bounded, backed-off RETRY — never a single fixed sleep
  /// before the first attempt — so the common case (no extension installed
  /// at all) pays nothing beyond the `NameHasOwner` check
  /// `probeLiveDispatch()` already short-circuits on.
  private static let liveDispatchRetryDelays: [Duration] = [
    .milliseconds(100), .milliseconds(300), .milliseconds(600), .milliseconds(1000),
  ]

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

    let controlService = startControlService(on: controlConnection, environment: environment)

    // T-P10I: `callConnection` below is `controlService` itself (which
    // owns `app.clipnest.Clipnest` via `SingleInstance.acquire` and
    // conforms to `DBusCalling` — see `ClipnestControlService`'s own
    // "demuxed outgoing calls" doc comment), never a second, separate
    // `DBusConnection` — a real GNOME Shell traced with `dbus-monitor`
    // showed the extension's `_checkSender` permanently (not racily)
    // denying every call sent from any OTHER connection.
    let shellHelperClient = makeShellHelperClient(
      sessionBusAddress: sessionBusAddress, callConnection: controlService)
    // See the "Process-lifetime ownership" doc comment above — this used
    // to survive only via an accidental retain cycle through the closures
    // wired below.
    Self.shellHelperClient = shellHelperClient
    wireShellHelper(shellHelperClient, environment: environment)

    startTray(sessionBusAddress: sessionBusAddress, environment: environment)

    installHotkeys(sessionBusAddress: sessionBusAddress, shellHelperClient: shellHelperClient)
  }

  @discardableResult
  private static func startControlService(
    on connection: DBusConnection, environment: LinuxAppEnvironment
  ) -> ClipnestControlService {
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
    return service
  }

  /// `callConnection` is the app's `app.clipnest.Clipnest`-owning identity
  /// (`ClipnestControlService`, conforming to `DBusCalling` — see its
  /// "T-P10I: demuxed outgoing calls" doc comment) — NOT a fresh
  /// `DBusConnection` of its own. `signalConnection` stays a separate,
  /// dedicated connection: the extension's `_checkSender` only gates
  /// METHOD CALLS it receives, never the broadcast signals it emits, so
  /// this one never needed a trusted identity — only its own uncontested
  /// reader thread (`ShellHelperClient.readLoop`).
  private static func makeShellHelperClient(
    sessionBusAddress: String, callConnection: any DBusCalling
  ) -> ShellHelperClient? {
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
    // T-P10I: re-resolve the hotkey backend live every time capabilities
    // change — covers the extension being enabled well AFTER this app
    // already finished `installHotkeys` (a one-shot resolution at launch
    // would never see it), and covers it being disabled or crashing
    // mid-session (falls back to the always-installed GSettings floor —
    // see `resolveAndApplyHotkeyBackend`'s doc comment). This closure used
    // to be left at its default no-op: declared, documented as the live
    // "took effect with no restart" signal every other capability-gated
    // caller here already uses, but never actually wired to anything for
    // hotkeys specifically — exactly the "declared but nobody wires it"
    // gap `coding-standards.md` warns a cross-platform seam against, even
    // though this one is Linux-only rather than cross-platform.
    client.onCapabilitiesChanged = { _ in
      Task { @MainActor in reconcileHotkeyBackend(shellHelperClient: client) }
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
  ///
  /// Probes the portal once (its availability is a GNOME-Shell-version
  /// fact, not something that changes live) and caches it, then hands off
  /// to `reconcileHotkeyBackend` — the same entry point
  /// `onCapabilitiesChanged` uses for every LIVE re-resolution over the
  /// rest of the session (see that closure's doc comment in
  /// `wireShellHelper`, and T-P10I's fix in `reconcileHotkeyBackend`'s own
  /// doc comment).
  private static func installHotkeys(
    sessionBusAddress: String, shellHelperClient: ShellHelperClient?
  ) {
    if let probeConnection = DBusConnection.connect(
      address: sessionBusAddress, timeout: sessionBusConnectTimeout)
    {
      cachedGlobalShortcutsPortalAvailable = GlobalShortcutsPortalClient.isAvailable(
        on: probeConnection, timeout: .milliseconds(500))
    }
    reconcileHotkeyBackend(shellHelperClient: shellHelperClient)
  }

  /// The single entry point that (re-)resolves and applies the hotkey
  /// backend — called once at startup (`installHotkeys`) and again, live,
  /// every time `ShellHelperClient.onCapabilitiesChanged` fires
  /// (`wireShellHelper`). Does the fast, synchronous resolution/apply pass
  /// itself, then — only if the extension claims hotkeys but this pass's
  /// probe didn't confirm live dispatch — hands off to
  /// `retryLiveDispatchProbeIfNeeded` for a bounded, non-blocking retry.
  @MainActor
  private static func reconcileHotkeyBackend(shellHelperClient: ShellHelperClient?) {
    let confirmed = resolveAndApplyHotkeyBackend(shellHelperClient: shellHelperClient)
    if !confirmed {
      retryLiveDispatchProbeIfNeeded(shellHelperClient: shellHelperClient)
    }
  }

  /// Resolves `HotkeyBackendResolver`'s decision from fresh inputs, logs it
  /// (only when it actually changed from last time, so a steady-state
  /// re-resolution — e.g. a `CapabilitiesChanged` notice that changed
  /// nothing — doesn't spam the log), and applies it. Returns whether the
  /// live-dispatch probe was confirmed this pass, so `reconcileHotkeyBackend`
  /// knows whether a retry is worth scheduling.
  ///
  /// **T-P10I.** This used to run exactly once, synchronously, at startup,
  /// with no way to ever revisit the decision — so a probe that lost the
  /// startup race (see `retryLiveDispatchProbeIfNeeded`'s doc comment) was
  /// wrong for the rest of the process's life, and an extension enabled
  /// AFTER that one run (or one that crashed/was disabled mid-session)
  /// never changed anything either, despite `ShellHelperClient`'s whole
  /// design being built around "capabilities changing takes effect live,
  /// no restart" (see that class's own doc comment). This function is now
  /// callable any number of times and always re-derives fresh inputs
  /// rather than trusting stale ones — never trusting `Capabilities` alone
  /// for the reason `HotkeyBackend.shellExtensionKeybinding`'s doc comment
  /// gives, on every single call, not just the first.
  ///
  /// The GSettings floor is installed UNCONDITIONALLY, even when the
  /// Shell-extension tier is selected — the fix for the other half of this
  /// task's brief: "if the probe succeeds but signal delivery later
  /// breaks, the user must not be left with a dead hotkey and no
  /// fallback." Nothing here (or anywhere else) actively health-checks
  /// `ShortcutActivated` delivery after the fact — the mechanisms that DO
  /// notice a regression (`NameOwnerChanged`/`CapabilitiesChanged`) don't
  /// fire for, say, a lost Mutter keybinding grab with the extension
  /// otherwise healthy. Keeping the floor's OWN, independent accelerator
  /// always bound means a global toggle keeps working through that failure
  /// mode too, without needing an ongoing heartbeat/poll loop.
  /// `ToggleHotkeyFloorBinding.reinstallFloor`'s doc comment already
  /// established this exact "safe to have both bound at once" precedent
  /// for its own call site (a user-initiated rebind, via a DIFFERENT
  /// accelerator than the extension's own keybinding schema uses — Mutter
  /// grants each its own grab); this generalizes it to every resolution.
  /// `GSettingsCustomKeybinding.install` is idempotent — safe to call
  /// repeatedly with no observable effect when nothing changed.
  @discardableResult
  @MainActor
  private static func resolveAndApplyHotkeyBackend(shellHelperClient: ShellHelperClient?) -> Bool {
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

    let backend = HotkeyBackendResolver.resolve(
      shellExtensionKeybindingAvailable: shellExtensionAvailable,
      shellExtensionLiveDispatchConfirmed: shellExtensionLiveDispatchConfirmed,
      // See `HotkeyBackend.xGrabKey`'s doc comment: no `CXlib` dependency
      // is declared for this target, so this tier can never be attempted
      // from here.
      xGrabKeyAvailable: false,
      globalShortcutsPortalAvailable: cachedGlobalShortcutsPortalAvailable)

    if backend != lastResolvedHotkeyBackend {
      let previous = lastResolvedHotkeyBackend
      logger.info(
        "hotkey backend resolved: \(String(describing: backend))"
          + (previous.map { " (was \(String(describing: $0)))" } ?? ""))
      lastResolvedHotkeyBackend = backend
    }

    // Always installed — see this method's doc comment on why the floor is
    // never skipped, even for `.shellExtensionKeybinding`.
    installGSettingsFloor()

    return shellExtensionLiveDispatchConfirmed
  }

  /// **T-P10I.** `probeLiveDispatch()` can lose a real, confirmed
  /// cross-process race the FIRST time it's called: the extension's own
  /// `_checkSender` only allows a call from the CURRENT owner of
  /// `app.clipnest.Clipnest`, which the extension learns asynchronously
  /// via its own `Gio.bus_watch_name` — a second, independent D-Bus round
  /// trip through a DIFFERENT process (`gnome-shell`) that has not
  /// necessarily completed by the time this app's probe arrives a few
  /// milliseconds after claiming that name. Confirmed live
  /// (`packaging/linux/gnome-shell-test/README.md`'s "Findings" section):
  /// the identical `GetPointer` call, made from a throwaway process that
  /// claims `app.clipnest.Clipnest` and then simply waits before calling,
  /// succeeds every time — the access-denied-vs-success split is purely a
  /// function of how long the caller waited after claiming the name, not
  /// anything else this app's own connect/probe ordering can eliminate
  /// (there is no signal to watch for "the extension's internal bookkeeping
  /// about MY name has caught up" — the ShellHelper name itself is
  /// typically already owned and stable the whole time).
  ///
  /// So: bounded RETRY, not a single fixed sleep before the first attempt.
  /// Runs entirely on a dedicated background `Thread` (matching this
  /// module's own established pattern for blocking D-Bus work — see
  /// `ShellHelperClient.readLoop`/`StatusNotifierTray`'s receive thread) —
  /// NEVER the `@MainActor` this function itself, and the GTK main loop,
  /// run on — so the common case (no extension installed at all, which
  /// short-circuits via `probeLiveDispatch()`'s own `isPresent` check
  /// before this is ever called at all — see `reconcileHotkeyBackend`)
  /// pays nothing, and even the retried case never blocks startup or the
  /// UI thread for any part of its ~2s bound.
  private static func retryLiveDispatchProbeIfNeeded(shellHelperClient: ShellHelperClient?) {
    guard let shellHelperClient, shellHelperClient.currentCapabilities.canDeliverShortcuts else {
      return
    }

    // Read the actor-isolated schedule here, on the `@MainActor` this
    // function itself runs on, and hand the background `Thread` below a
    // plain, already-`Sendable` local copy — the closure it runs is
    // inferred `@Sendable` and may not reference an actor-isolated STATIC
    // property directly, even one whose VALUE type is `Sendable`.
    let delays = liveDispatchRetryDelays
    let thread = Thread {
      for delay in delays {
        Thread.sleep(forTimeInterval: DurationConversion.timeInterval(for: delay))
        guard shellHelperClient.currentCapabilities.canDeliverShortcuts else {
          // Lost the capability entirely mid-retry (extension disabled) —
          // `onCapabilitiesChanged` (wired in `wireShellHelper`) already
          // reconciles that transition live; nothing left for this
          // schedule to confirm.
          return
        }
        if shellHelperClient.probeLiveDispatch() {
          Task { @MainActor in reconcileHotkeyBackend(shellHelperClient: shellHelperClient) }
          return
        }
      }
      Task { @MainActor in
        logger.info(
          "shell-extension live-dispatch probe still unconfirmed after \(delays.count) retries — keeping the resolved fallback backend"
        )
      }
    }
    thread.name = "ShellHelperClient.liveDispatchRetry"
    thread.start()
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
