import ClipnestCore
import ClipnestPlatformLinux
import Foundation

/// Pure request -> handler-closure -> reply routing for
/// `app.clipnest.Control`/`org.freedesktop.Application`/
/// `org.freedesktop.DBus.Properties` — extracted from `ClipnestControlService`
/// so it's constructible and testable WITHOUT a real `DBusConnection`
/// (`DBusConnection` has no fake-able initializer; its only constructor is
/// `connect(address:timeout:)`, a real socket connect+SASL handshake).
/// `ClipnestControlService` owns exactly one of these and calls `handle(_:
/// message:)` from its receive loop; `ClipnestControlServiceDispatchTests`
/// constructs one directly against canned requests, with no thread/socket
/// involved.
final class ClipnestControlDispatcher {
  private let capabilities: [String]

  var onTogglePicker: () -> Void = {}
  var onShowPicker: (ShowPickerOptions) -> Void = { _ in }
  var onHidePicker: () -> Void = {}
  var onExpandSnippet: () -> Void = {}
  var onOpenSettings: () -> Void = {}

  init(capabilities: [String]) {
    self.capabilities = capabilities
  }

  func handle(_ request: ClipnestControlRequest, message: DBusMessage) -> DBusMessage? {
    switch request {
    case .togglePicker, .activate:
      onTogglePicker()
      return ClipnestControlReplies.empty(replyingTo: message)
    case .showPicker(let options):
      onShowPicker(options)
      return ClipnestControlReplies.empty(replyingTo: message)
    case .hidePicker:
      onHidePicker()
      return ClipnestControlReplies.empty(replyingTo: message)
    case .expandSnippet:
      onExpandSnippet()
      return ClipnestControlReplies.empty(replyingTo: message)
    case .openSettings:
      onOpenSettings()
      return ClipnestControlReplies.empty(replyingTo: message)
    case .open(let paths):
      // `org.freedesktop.Application.Open` doubles as this app's
      // CLI-forwarding transport (see `SingleInstance.forwardArguments`):
      // a hotkey-bound `clipnest --toggle-picker`/`--expand-snippet`
      // invocation that lost the single-instance race forwards its argv
      // here as `Open`'s `uris` array. This app has no real per-file
      // action of its own (it isn't a document viewer), so anything that
      // isn't a recognized CLI flag degrades to the same thing a bare
      // `Activate` does: bring the picker up.
      switch LinuxAppCLI.parse(paths) {
      // `.version`/`.help` can't actually arrive here in practice —
      // `LinuxAppLifecycle.run(arguments:)` intercepts and `exit(0)`s on
      // both before a launch ever reaches `SingleInstance.forwardArguments`
      // (T-BB2 fix) — but `LinuxAppCLICommand`'s switch must stay
      // exhaustive, so they degrade the same way an unrecognized flag
      // already does: bring the picker up.
      case .togglePicker, .version, .help, .none: onTogglePicker()
      case .expandSnippet: onExpandSnippet()
      }
      return ClipnestControlReplies.empty(replyingTo: message)
    case .activateAction(let name):
      switch name {
      case ClipnestControlMember.expandSnippet.lowercased(): onExpandSnippet()
      case ClipnestControlMember.openSettings.lowercased(): onOpenSettings()
      default: onTogglePicker()
      }
      return ClipnestControlReplies.empty(replyingTo: message)
    case .ping:
      return ClipnestControlReplies.empty(replyingTo: message)
    case .getCapabilities:
      return ClipnestControlReplies.capabilities(capabilities, replyingTo: message)
    case .getAllProperties:
      return ClipnestControlReplies.allProperties(capabilities, replyingTo: message)
    case .malformed:
      return ClipnestControlReplies.invalidArgs(replyingTo: message)
    case .unknown:
      return ClipnestControlReplies.unknownMethod(replyingTo: message)
    }
  }
}

/// The real `app.clipnest.Clipnest` D-Bus service: owns the well-known bus
/// name (via `SingleInstance.acquire`, `DO_NOT_QUEUE` — see that type's
/// doc comment) and answers incoming calls by routing them through
/// `ClipnestControlDispatcher` to the plain closures the composition root
/// wires up (exposed here as computed passthroughs so callers configure
/// this ONE object, same shape as before this dispatcher was extracted).
///
/// Runs its receive loop on a dedicated background thread (mirrors
/// `ClipnestPlatformLinux.ATSPIFocusTracker`'s identical shape) — every
/// handler closure it invokes must itself hop to `@MainActor` before
/// touching `LinuxAppEnvironment`'s state, since this thread is not the
/// GTK/main thread. Manual-verify only: there is no session bus in the CI
/// container this ships to; `ClipnestControlDispatcher`/
/// `ClipnestControlRequest.decode`/`ClipnestControlReplies` (the pure
/// logic this loop is built from) are unit-tested directly instead.
public final class ClipnestControlService: @unchecked Sendable {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "ClipnestControlService")

  private let connection: DBusConnection
  private let dispatcher: ClipnestControlDispatcher
  private var receiveThread: Thread?

  // MARK: - T-P10I: demuxed outgoing calls on this SAME identity connection
  //
  // The devops investigation behind T-P10I ("gnome-shell-test/README.md"'s
  // Findings) diagnosed the Shell-extension probe's failure as a pure
  // ownership-PROPAGATION race, reproduced with a throwaway script that
  // used ONE D-Bus connection for both claiming `app.clipnest.Clipnest`
  // AND calling the extension. Tracing the REAL app's traffic with
  // `dbus-monitor` against a real GNOME Shell (this task) found a
  // different, deterministic (not racy) defect that misdiagnosis missed:
  // `ShellHelperClient.callConnection` (built in `LinuxAppLifecycle
  // .makeShellHelperClient` as a brand-new, separate `DBusConnection`) has
  // a DIFFERENT unique name than `connection` here — the one that actually
  // owns `app.clipnest.Clipnest` (claimed via `SingleInstance.acquire`).
  // The extension's `_checkSender` (`extension/src/core/service.js`)
  // denies EVERY SendKeyChord/GetPointer/PlaceWindow/etc. call whose
  // sender isn't the CURRENT OWNER of `app.clipnest.Clipnest` — captured
  // live: `error_name=org.freedesktop.DBus.Error.AccessDenied` on every
  // single attempt across a 2-second bounded retry window, not just the
  // first. No amount of waiting fixes a connection-identity mismatch; only
  // sending from the connection that actually owns the name does.
  //
  // Fix: `ClipnestControlService` — the one object that already owns
  // `connection` and already runs the one thread reading it — ALSO
  // exposes a `DBusCalling`-conforming outgoing-call path
  // (`call(_:timeout:)`) that sends on `connection` (so the sender the
  // extension sees really is `app.clipnest.Clipnest`'s owner) and
  // correlates the reply via `receiveLoop()`'s own read, instead of
  // opening — and reading — a second, uncorrelated connection. This keeps
  // `receiveLoop()` the SINGLE reader of `connection` (the exact hazard
  // `ClipnestPlatformLinux.DBusConnection`'s own doc comment warns a
  // shared connection needs a demultiplexer for), rather than also having
  // some other thread call `connection.receiveOneMessage(_:)` directly and
  // race it for the next buffered message.
  //
  // Scope: only the non-fd `DBusCalling.call(_:timeout:)` overload is
  // implemented (`SendKeyChord`/`GetPointer`/`PlaceWindow`/etc. — every
  // ShellHelper1 member the hotkey/paste/placement path needs). The
  // fd-attaching overload (`ReadClipboard`/`SetClipboard`) is NOT — it
  // would need `receiveLoop()` switched to the fd-aware receive path too,
  // a larger, separate change out of this task's scope (clipboard-via-
  // extension was already just as broken before this fix, for the
  // identical sender-mismatch reason — this is not a regression).
  private let pendingCallCondition = NSCondition()
  private var pendingCallSerials: Set<UInt32> = []
  private var resolvedReplies: [UInt32: DBusMessage] = [:]

  /// Sends `message` on the SAME connection that owns `app.clipnest
  /// .Clipnest` (see the "T-P10I" doc comment above) and blocks (up to
  /// `timeout`) for its `METHOD_RETURN`/`ERROR` reply, which `receiveLoop()`
  /// resolves on this service's own receive thread. `nil` on send failure
  /// or timeout — matches `DBusConnection.call(_:timeout:)`'s own contract,
  /// so every degrade-per-feature caller in `ShellHelperClient` (built
  /// against the `DBusCalling` protocol, not a concrete connection type)
  /// needs no change to use this instead.
  public func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage? {
    var outgoing = message
    let serial = connection.allocateSerial()
    outgoing.serial = serial

    pendingCallCondition.lock()
    pendingCallSerials.insert(serial)
    pendingCallCondition.unlock()

    guard connection.send(outgoing) else {
      pendingCallCondition.lock()
      pendingCallSerials.remove(serial)
      pendingCallCondition.unlock()
      return nil
    }

    pendingCallCondition.lock()
    defer { pendingCallCondition.unlock() }
    let deadline = Date().addingTimeInterval(DurationConversion.timeInterval(for: timeout))
    while resolvedReplies[serial] == nil {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      _ = pendingCallCondition.wait(until: Date().addingTimeInterval(remaining))
    }
    let reply = resolvedReplies.removeValue(forKey: serial)
    pendingCallSerials.remove(serial)
    return reply
  }

  public var onTogglePicker: () -> Void {
    get { dispatcher.onTogglePicker }
    set { dispatcher.onTogglePicker = newValue }
  }
  public var onShowPicker: (ShowPickerOptions) -> Void {
    get { dispatcher.onShowPicker }
    set { dispatcher.onShowPicker = newValue }
  }
  public var onHidePicker: () -> Void {
    get { dispatcher.onHidePicker }
    set { dispatcher.onHidePicker = newValue }
  }
  public var onExpandSnippet: () -> Void {
    get { dispatcher.onExpandSnippet }
    set { dispatcher.onExpandSnippet = newValue }
  }
  public var onOpenSettings: () -> Void {
    get { dispatcher.onOpenSettings }
    set { dispatcher.onOpenSettings = newValue }
  }

  public init(connection: DBusConnection, capabilities: [String]) {
    self.connection = connection
    self.dispatcher = ClipnestControlDispatcher(capabilities: capabilities)
  }

  /// Starts the receive/dispatch loop. Call only AFTER
  /// `SingleInstance.acquire` returned `.becomePrimary` on this exact
  /// `connection` — a connection that lost the name-ownership race has no
  /// business answering calls addressed to it.
  public func start() {
    let thread = Thread { [weak self] in self?.receiveLoop() }
    thread.name = "ClipnestControlService"
    receiveThread = thread
    thread.start()
  }

  private func receiveLoop() {
    // T-LX2 diagnostic: proof the loop is actually alive at all — see
    // `LinuxAppLifecycle.controlService`'s doc comment for the T-LX1 bug
    // where this line never printed because this method never ran.
    Self.logger.info("D-Bus control service receive loop started")
    while true {
      // No message within the poll interval is this loop's normal idle
      // state, not a rejection — see `ClipnestControlReceiveRejection`'s
      // doc comment for why this one `continue` is deliberately silent.
      guard let message = connection.receiveOneMessage(timeout: .seconds(1)) else { continue }
      guard let request = ClipnestControlRequest.decode(message) else {
        // T-P10I: before logging this as a rejected/unrecognized message,
        // check whether it's actually the reply to one of THIS service's
        // own outgoing `call(_:timeout:)` invocations (see that method's
        // doc comment) — a `METHOD_RETURN`/`ERROR` never decodes as a
        // `ClipnestControlRequest` (it isn't a method call at all), so
        // without this check every such reply would be silently logged as
        // "not a method call" and the waiting `call(_:timeout:)` caller
        // would time out despite the reply having actually arrived.
        if let replySerial = message.replySerial {
          pendingCallCondition.lock()
          let isPending = pendingCallSerials.contains(replySerial)
          if isPending {
            resolvedReplies[replySerial] = message
            pendingCallCondition.broadcast()
          }
          pendingCallCondition.unlock()
          if isPending { continue }
        }
        Self.logger.debug(ClipnestControlReceiveRejection.notAMethodCall(message).logDescription)
        continue
      }
      guard let reply = dispatcher.handle(request, message: message) else {
        Self.logger.info(ClipnestControlReceiveRejection.noReplyProduced(message).logDescription)
        continue
      }
      var outgoing = reply
      outgoing.serial = connection.allocateSerial()
      connection.send(outgoing)
    }
  }
}

/// T-P10I: lets `ShellHelperClient` (built against `DBusCalling`, never a
/// concrete connection type — see that protocol's own doc comment) send
/// its privileged, sender-checked calls through THIS service's identity
/// connection instead of an uncorrelated one of its own — see the
/// "T-P10I: demuxed outgoing calls" doc comment on `ClipnestControlService`
/// for why that's required, not optional. Only the plain `call(_:timeout:)`
/// overload is implemented above; the fd-attaching overload falls through
/// to `DBusCalling`'s own default (`nil` — "unsupported"), same as every
/// other non-fd-aware conformer.
extension ClipnestControlService: DBusCalling {}
