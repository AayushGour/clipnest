import ClipnestCore
import ClipnestPlatformLinux
import Foundation
import Synchronization

#if canImport(Glibc)
  import Glibc
#endif

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

  /// Fired for every `ClipboardChanged` signal — see
  /// `ShellHelperResponses.parseClipboardChanged`'s doc comment for why
  /// `source`'s `a{sv}` contents aren't surfaced. `selection` is the raw
  /// `MetaSelectionType` ordinal (`ShellHelperClipboardSelection`'s doc
  /// comment) rather than the typed enum, since a future Mutter selection
  /// type this app doesn't recognize should still be observable rather
  /// than silently dropped by this signal.
  public var onClipboardChanged:
    (
      _ selection: UInt32, _ clipboardSerial: UInt64, _ mimeTypes: [String], _ ownerIsUs: Bool
    ) -> Void = { _, _, _, _ in }

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
  /// (the bus daemon's own signal about who owns the name), AND for every
  /// signal the ShellHelper OBJECT itself emits (`ShortcutActivated`/
  /// `ClipboardChanged`/`CapabilitiesChanged` — see
  /// `ShellHelperRequests.addSignalsMatch`'s doc comment for T-P10J, the
  /// bug this second call fixes: without it, this class's OWN
  /// `readLoop` parsing code for those three signals was unreachable on
  /// every machine, ever), then starts the background signal-read loop.
  /// Call once, after `refreshCapabilities()`'s initial call.
  public func startWatching() {
    guard let signalConnection else { return }
    _ = signalConnection.call(
      DBusStandardRequests.addNameOwnerChangedMatch(
        forName: ShellHelperName.busName, serial: 20), timeout: timeout)
    _ = signalConnection.call(ShellHelperRequests.addSignalsMatch(serial: 21), timeout: timeout)

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
      if ShellHelperResponses.isCapabilitiesChanged(message) {
        _ = refreshCapabilities()
        continue
      }
      if let action = ShellHelperResponses.parseShortcutActivated(message) {
        let options = ShellHelperResponses.showPickerOptions(forAction: action)
        onShortcutActivated(action.action, options)
        continue
      }
      if let changed = ShellHelperResponses.parseClipboardChanged(message) {
        onClipboardChanged(
          changed.selection, changed.clipboardSerial, changed.mimeTypes, changed.ownerIsUs)
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

  /// The live-dispatch half of `HotkeyBackendResolver`'s capability-trap
  /// fix — see that type's doc comment on `.shellExtensionKeybinding`.
  /// Deliberately bypasses `currentCapabilities.supports(.pointer)`
  /// (unlike `getPointer()` above): the whole point is to NOT trust a
  /// self-reported capability string, so this sends `GetPointer` directly
  /// and requires a real, correctly-shaped reply. The only capability
  /// state this DOES trust is `isPresent` (`NameHasOwner`'s answer) — a
  /// bus-daemon-verified fact about whether ANY process owns the name, not
  /// a claim the extension's own JS makes about itself — purely to skip a
  /// pointless round trip when there is provably no extension to call.
  public func probeLiveDispatch() -> Bool {
    guard currentCapabilities.isPresent else { return false }
    let reply = callConnection.call(ShellHelperRequests.getPointer(serial: 34), timeout: timeout)
    return reply.flatMap(ShellHelperResponses.parseGetPointer) != nil
  }

  public func placeWindow(windowToken: String, x: Int32, y: Int32, flags: UInt32) -> Bool {
    guard currentCapabilities.supports(.placement) else { return false }
    let reply = callConnection.call(
      ShellHelperRequests.placeWindow(
        windowToken: windowToken, x: x, y: y, flags: flags, serial: 32),
      timeout: timeout)
    return reply.flatMap(ShellHelperResponses.parseBooleanReply) ?? false
  }

  // MARK: - Clipboard payload calls (task P8-C) — every real descriptor
  // that crosses these methods is CALLER-OWNED (see each method's doc
  // comment); none of them is ever silently leaked or double-closed.

  /// `SetClipboardWatch(enable, include_primary)` — has no reply payload,
  /// so success is just "the extension acknowledged the call at all."
  @discardableResult
  public func setClipboardWatch(enable: Bool, includePrimary: Bool) -> Bool {
    guard currentCapabilities.supports(.clipboard) else { return false }
    let reply = callConnection.call(
      ShellHelperRequests.setClipboardWatch(
        enable: enable, includePrimary: includePrimary, serial: 40),
      timeout: timeout)
    return reply?.type == .methodReturn
  }

  public func getClipboardMimeTypes(
    selection: ShellHelperClipboardSelection
  ) -> (mimeTypes: [String], clipboardSerial: UInt64)? {
    guard currentCapabilities.supports(.clipboard) else { return nil }
    let reply = callConnection.call(
      ShellHelperRequests.getClipboardMimeTypes(selection: selection, serial: 41),
      timeout: timeout)
    return reply.flatMap(ShellHelperResponses.parseGetClipboardMimeTypes)
  }

  /// `ReadClipboard(selection, mimetype) -> fd`. On success, the returned
  /// `Int32` is a REAL, now-open descriptor this call's caller now owns —
  /// it must close it exactly once (typically after reading the payload
  /// off it). Returns `nil` on any failure — capability not negotiated,
  /// timeout, or a reply whose shape doesn't match (in which case any fd
  /// that DID arrive is closed here rather than leaked, since nobody else
  /// can claim it).
  public func readClipboard(
    selection: ShellHelperClipboardSelection, mimetype: String
  ) -> Int32? {
    guard currentCapabilities.supports(.clipboard) else { return nil }
    guard
      let (reply, fileDescriptors) = callConnection.call(
        ShellHelperRequests.readClipboard(selection: selection, mimetype: mimetype, serial: 42),
        attachingFileDescriptors: [], timeout: timeout)
    else { return nil }
    guard ShellHelperResponses.isReadClipboardReplyShapeValid(reply), let fd = fileDescriptors.first
    else {
      for fd in fileDescriptors { Self.closeLeakedFileDescriptor(fd) }
      return nil
    }
    return fd
  }

  /// `SetClipboard(mimetype, fd) -> serial`. `fileDescriptor` is CALLER-
  /// OWNED both before and after this call — this method attaches it to
  /// the outgoing message but never closes it (mirrors
  /// `DBusConnection.send(_:attachingFileDescriptors:)`'s own contract);
  /// the caller closes it same as it would any fd it opened itself, once
  /// it's done writing to/handing off the write end.
  public func setClipboard(mimetype: String, fileDescriptor: Int32) -> UInt64? {
    guard currentCapabilities.supports(.clipboard) else { return nil }
    let result = callConnection.call(
      ShellHelperRequests.setClipboard(mimetype: mimetype, serial: 43),
      attachingFileDescriptors: [fileDescriptor], timeout: timeout)
    guard let (reply, fileDescriptors) = result else { return nil }
    // A conforming extension never attaches fds to THIS reply — close any
    // that show up anyway rather than leak them.
    for fd in fileDescriptors { Self.closeLeakedFileDescriptor(fd) }
    return ShellHelperResponses.parseSetClipboardReply(reply)
  }

  #if canImport(Glibc)
    private static func closeLeakedFileDescriptor(_ fd: Int32) {
      Glibc.close(fd)
    }
  #else
    private static func closeLeakedFileDescriptor(_ fd: Int32) {}
  #endif
}
