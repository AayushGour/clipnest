import ClipnestCore
import ClipnestPlatformLinux
import Foundation
import Synchronization

/// Detects, negotiates with, and calls the optional GNOME Shell extension
/// (`app.clipnest.ShellHelper`) — see `ShellHelperCapabilities`'s doc
/// comment for the pure negotiation logic this wraps, and this task's
/// build step 4: "Detect `app.clipnest.ShellHelper` via `NameHasOwner`
/// and subscribe to `NameOwnerChanged` so enabling or disabling the
/// extension takes effect live, with no restart."
///
/// Two independent `DBusConnection`s, same reasoning
/// `ClipnestPlatformLinux.DBusConnection`'s own doc comment gives for
/// `ATSPIFocusTracker` vs. `ATSPITextAccessor`: `callConnection` does
/// strict send-then-block-for-this-reply round trips (capability refresh,
/// `SendKeyChord`, `GetFocusedApp`, ...); `signalConnection` only ever
/// reads unsolicited `NameOwnerChanged`/`CapabilitiesChanged`/
/// `ShortcutActivated` signals off a dedicated background thread. Manual-
/// verify only — there is no session bus in the CI container this ships
/// to; `ShellHelperCapabilities.negotiate`/`ShellHelperRequests`/
/// `ShellHelperResponses` (the pure logic this class is built from) are
/// unit-tested directly instead.
public final class ShellHelperClient: @unchecked Sendable {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "ShellHelperClient")

  private let callConnection: any DBusCalling
  private let signalConnection: DBusConnection?
  private let timeout: Duration
  private let state = Mutex<ShellHelperCapabilities>(.unavailable)
  private var signalReaderThread: Thread?

  /// Fired whenever a fresh negotiation (from a `NameOwnerChanged`
  /// observation, or `CapabilitiesChanged`) changes what the extension
  /// supports — the live "took effect with no restart" signal every
  /// degrade-per-feature caller (hotkeys, input synthesis, window
  /// placement) observes instead of polling.
  public var onCapabilitiesChanged: (ShellHelperCapabilities) -> Void = { _ in }

  /// Fired for every `ShortcutActivated` signal, already translated to
  /// `ShowPickerOptions` for the `toggle-picker` action (see
  /// `ShellHelperResponses.showPickerOptions(forAction:)`); the raw
  /// action name is passed through too so `expand-snippet` routes
  /// differently.
  public var onShortcutActivated:
    (
      _ action: String, _ options: ShowPickerOptions
    ) -> Void = { _, _ in }

  public init(
    callConnection: any DBusCalling, signalConnection: DBusConnection?,
    timeout: Duration = .milliseconds(250)
  ) {
    self.callConnection = callConnection
    self.signalConnection = signalConnection
    self.timeout = timeout
  }

  public var currentCapabilities: ShellHelperCapabilities { state.withLock { $0 } }

  /// Sends `NameHasOwner` + (if owned) `Properties.Get(Capabilities)`,
  /// updates the cached state, and fires `onCapabilitiesChanged` if it
  /// changed. Called once at startup and again every time
  /// `NameOwnerChanged`'s reader loop observes the watched name flip.
  @discardableResult
  public func refreshCapabilities() -> ShellHelperCapabilities {
    let hasOwnerReply = callConnection.call(
      DBusStandardRequests.nameHasOwner(ShellHelperName.busName, serial: 10), timeout: timeout)
    let hasOwner = hasOwnerReply.flatMap(DBusStandardResponses.parseBooleanReply) ?? false

    var rawCapabilities: [String] = []
    if hasOwner {
      let reply = callConnection.call(
        ShellHelperRequests.getCapabilities(serial: 11), timeout: timeout)
      rawCapabilities = reply.flatMap(ShellHelperResponses.parseCapabilities) ?? []
    }

    let negotiated = ShellHelperCapabilities.negotiate(
      nameHasOwner: hasOwner, rawCapabilities: rawCapabilities)
    let changed = state.withLock { current -> Bool in
      guard current != negotiated else { return false }
      current = negotiated
      return true
    }
    if changed { onCapabilitiesChanged(negotiated) }
    return negotiated
  }

  /// Sends `AddMatch` for `app.clipnest.ShellHelper`'s `NameOwnerChanged`
  /// and starts the background signal-read loop. Call once, after
  /// `refreshCapabilities()`'s initial call.
  public func startWatching() {
    guard let signalConnection else { return }
    _ = signalConnection.call(
      DBusStandardRequests.addNameOwnerChangedMatch(
        forName: ShellHelperName.busName, serial: 20), timeout: timeout)

    let thread = Thread { [weak self] in self?.readLoop(signalConnection) }
    thread.name = "ShellHelperClient"
    signalReaderThread = thread
    thread.start()
  }

  private func readLoop(_ connection: DBusConnection) {
    // Same T-LX1-class diagnostic `ClipnestControlService.receiveLoop()`
    // carries — proof this loop is actually alive; see
    // `LinuxAppLifecycle`'s "Process-lifetime ownership" doc comment for
    // why this class needed a deliberate external owner too.
    Self.logger.info("Shell-extension helper signal read loop started")
    while true {
      guard let message = connection.receiveOneMessage(timeout: .seconds(1)) else { continue }
      if DBusStandardResponses.parseNameOwnerChanged(message)?.name == ShellHelperName.busName {
        _ = refreshCapabilities()
        continue
      }
      if let action = ShellHelperResponses.parseShortcutActivated(message) {
        let options = ShellHelperResponses.showPickerOptions(forAction: action)
        onShortcutActivated(action.action, options)
      }
    }
  }

  // MARK: - Calls (best-effort — every failure degrades to "unsupported",
  // never a crash, matching `ATSPITextAccessor`'s identical contract).

  public func sendKeyChord(keyval: UInt32, modifiers: UInt32) -> Bool {
    guard currentCapabilities.supports(.paste) else { return false }
    let reply = callConnection.call(
      ShellHelperRequests.sendKeyChord(keyval: keyval, modifiers: modifiers, serial: 30),
      timeout: timeout)
    return reply.flatMap(ShellHelperResponses.parseBooleanReply) ?? false
  }

  public func getPointer() -> (x: Int32, y: Int32, monitor: Int32)? {
    guard currentCapabilities.supports(.pointer) else { return nil }
    let reply = callConnection.call(ShellHelperRequests.getPointer(serial: 31), timeout: timeout)
    return reply.flatMap(ShellHelperResponses.parseGetPointer)
  }

  public func placeWindow(windowToken: String, x: Int32, y: Int32, flags: UInt32) -> Bool {
    guard currentCapabilities.supports(.placement) else { return false }
    let reply = callConnection.call(
      ShellHelperRequests.placeWindow(
        windowToken: windowToken, x: x, y: y, flags: flags, serial: 32),
      timeout: timeout)
    return reply.flatMap(ShellHelperResponses.parseBooleanReply) ?? false
  }
}
