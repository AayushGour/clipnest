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
      case .togglePicker, .none: onTogglePicker()
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
  private let connection: DBusConnection
  private let dispatcher: ClipnestControlDispatcher
  private var receiveThread: Thread?

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
    while true {
      guard let message = connection.receiveOneMessage(timeout: .seconds(1)) else { continue }
      guard let request = ClipnestControlRequest.decode(message) else { continue }
      guard let reply = dispatcher.handle(request, message: message) else { continue }
      var outgoing = reply
      outgoing.serial = connection.allocateSerial()
      connection.send(outgoing)
    }
  }
}
