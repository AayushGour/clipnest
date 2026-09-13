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
  private let clipboardWriteTimeout: Duration
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

  /// `timeout` covers every member EXCEPT `SetClipboard` — see
  /// `clipboardWriteTimeout`'s doc comment for why that one call needs a
  /// budget an order of magnitude larger. 250 ms is not a guess: every
  /// OTHER member here (`NameHasOwner`/`Capabilities.Get`/`SendKeyChord`/
  /// `GetPointer`/`PlaceWindow`/`SetClipboardWatch`/
  /// `GetClipboardMimeTypes`/`ReadClipboard`) replies SYNCHRONOUSLY on the
  /// extension side (`extension/src/core/service.js`'s own header comment:
  /// every member uses the `Async`-suffixed dispatch shape GJS requires to
  /// see the invocation, but only `SetClipboardAsync` "is the one member
  /// that is genuinely asynchronous" — everything else calls
  /// `invocation.return_value(...)` immediately, before returning).
  /// `ReadClipboard` looks payload-shaped but isn't slow the same way:
  /// `readToFd`'s D-Bus reply is just a freshly-opened fd handed back
  /// immediately — the real byte transfer happens on `sel.transfer_async`
  /// AFTER the reply, fully decoupled from this timeout. Measured live
  /// (T-SHELLHELPER-TIMEOUT1, real GNOME 46 VM): every one of these
  /// synchronous-reply members round-trips in single-digit milliseconds in
  /// this codebase's existing manual verification passes — 250 ms already
  /// carries roughly an order of magnitude of headroom for them.
  public static let defaultTimeout: Duration = .milliseconds(250)

  /// `SetClipboard` is the one `ShellHelper1` member whose D-Bus reply
  /// waits on real, asynchronous GIO work (`SetClipboardAsync`'s
  /// `splice_async` draining the incoming pipe into memory before
  /// `Meta.SelectionSourceMemory` can take ownership — see that method's
  /// own doc comment in `extension/src/core/service.js`) scheduled on
  /// GNOME Shell's OWN main loop, which also drives compositing — a
  /// fundamentally different, load-dependent shape than every other
  /// member's instant, synchronous reply, so it gets its own budget rather
  /// than sharing `timeout`/`defaultTimeout`.
  ///
  /// **Measured, not guessed (T-SHELLHELPER-TIMEOUT1):** an EARLIER
  /// diagnosis in this same investigation claimed this call itself
  /// measured "596ms and 613ms" and blamed `defaultTimeout` (250 ms) for
  /// cutting it off. That number was requoted from a DIFFERENT log line —
  /// `LinuxClipboardSelectionReplacer`'s "write propagation" total (its own
  /// separate ~500 ms `copyMaxWait` polling ceiling firing because the call
  /// never reached the wire at all) — and was never re-verified against
  /// this call's own round trip. It was also standing on a second, real
  /// bug this task found and fixed: `ClipnestControlService`'s
  /// `DBusCalling` conformance never implemented the fd-attaching overload
  /// `SetClipboard`/`ReadClipboard` need, so it silently fell through to
  /// that protocol's "unsupported" `nil` default — `SetClipboard` was
  /// returning `elapsedMs=0 gotReply=false` on every attempt, REGARDLESS
  /// of the timeout value, since it never sent a single byte (see
  /// `ClipnestControlService.swift`'s "T-SHELLHELPER-TIMEOUT1 correction"
  /// doc comment for the fix). With that fixed and the call genuinely
  /// reaching the extension, 11 live trials on the same real GNOME 46 VM
  /// (Firefox end-to-end, this exact call site) measured **2, 4, 4, 7, 12,
  /// 12, 18, 22, 42, 43, 70 ms** — max 70 ms, mean ~21 ms. 1000 ms is
  /// chosen over that real distribution, not the retracted one: >14x the
  /// observed worst case on a VM that is itself already a pessimistic
  /// environment for this measurement (software GL rendering — `MESA:
  /// error: ZINK: failed to choose pdev` — and an unrecognized virtualized
  /// CPU vendor for `onnxruntime`'s cpuid probe), leaving real headroom for
  /// a slower physical machine and for snippet bodies far larger than this
  /// test's, while staying bounded: this call blocks its caller's thread
  /// synchronously (`ClipnestControlService.call`'s `NSCondition.wait`,
  /// invoked from `LinuxClipboardSelectionReplacer`'s `@MainActor` body via
  /// `privilegedTextWriter`), so an unresponsive/hung extension must not be
  /// able to freeze the GTK main loop for longer than this one, rare,
  /// degraded-capability call ever needs.
  public static let defaultClipboardWriteTimeout: Duration = .milliseconds(1000)

  public init(
    callConnection: any DBusCalling, signalConnection: DBusConnection?,
    timeout: Duration = ShellHelperClient.defaultTimeout,
    clipboardWriteTimeout: Duration = ShellHelperClient.defaultClipboardWriteTimeout
  ) {
    self.callConnection = callConnection
    self.signalConnection = signalConnection
    self.timeout = timeout
    self.clipboardWriteTimeout = clipboardWriteTimeout
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
    // Metadata-only elapsed-time diagnostic (T-SHELLHELPER-TIMEOUT1): the
    // ONE call on this client whose reply waits on real async work rather
    // than an instant synchronous reply (see `clipboardWriteTimeout`'s doc
    // comment) — worth its own permanent round-trip log line for the same
    // reason `LinuxClipboardSelectionReplacer` logs elapsed ms throughout
    // its own transaction: this exact line is what caught both the
    // originally mis-attributed 250 ms timeout theory AND the real
    // `ClipnestControlService` fd-routing bug live, and will catch a
    // regression in either just as fast. Never logs `mimetype`/payload
    // bytes, only booleans/durations — same privacy discipline as every
    // other `ClipnestLogger` call site in this codebase.
    let callStart = ProcessInfo.processInfo.systemUptime
    let result = callConnection.call(
      ShellHelperRequests.setClipboard(mimetype: mimetype, serial: 43),
      attachingFileDescriptors: [fileDescriptor], timeout: clipboardWriteTimeout)
    let callElapsedMs = Int((ProcessInfo.processInfo.systemUptime - callStart) * 1000)
    Self.logger.notice(
      "SetClipboard round trip: elapsedMs=\(callElapsedMs) gotReply=\(result != nil)"
    )
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

  #if canImport(Glibc)
    /// Plain-text convenience over `setClipboard(mimetype:fileDescriptor:)`
    /// for callers that only ever have an in-memory `String`, never an fd
    /// of their own — creates the pipe, writes `text`'s UTF-8 bytes into
    /// the write end, hands the read end to `setClipboard`, and closes
    /// both ends itself (the write end right after the single `write(2)`;
    /// the read end after the D-Bus call returns, per `setClipboard`'s own
    /// "caller-owned both before and after" contract).
    ///
    /// **T-SNIPPET-FF1's actual reason for existing:** this routes through
    /// GNOME Shell's PRIVILEGED `Meta.Selection.set_owner` (the extension's
    /// `ClipboardWatcher.setClipboard`, `extension/src/core/clipboard.js`)
    /// rather than `GTKClipboardWriting`'s `gdk_clipboard_set_text`. GDK's
    /// Wayland clipboard backend needs a FRESH input-event serial from
    /// Clipnest's own `GdkWaylandSeat` before it will call
    /// `wl_data_device_set_selection` at all (confirmed against GTK's own
    /// Wayland backend source, `gdk/wayland/gdkclipboard-wayland.c` +
    /// `gdkdevice-wayland.c`'s `gdk_wayland_device_set_selection`) — a
    /// background process reacting to a global hotkey (no Clipnest window
    /// ever gains keyboard focus) never has one, so the compositor
    /// SILENTLY ignores the request per Wayland's anti-clipboard-hijack
    /// protocol design: no error, no `false` return, nothing — confirmed
    /// live (VM repro, 2026-09-13): `GTKClipboardWriting.writeString`
    /// reported success every time, yet three independent readers (this
    /// app's own `X11ClipboardConnection` watcher, a raw `XConvertSelection`
    /// probe run mid-transaction, and the target app's own subsequent
    /// paste) all still saw the PRE-expansion clipboard content. `Meta
    /// .Selection.set_owner` is the compositor's OWN internal API — no
    /// client-side Wayland protocol round trip, hence no input-serial gate
    /// — and (confirmed via `clipboard.js`'s `ClipboardWatcher.start()`,
    /// which watches this exact same `global.display.get_selection()`
    /// object's `owner-changed` signal) firing it ALSO makes mutter
    /// re-own the X11 CLIPBOARD selection exactly like any other
    /// `MetaSelection::owner-changed`, so `LinuxClipboardSelectionReplacer`
    /// 's existing `waitForChange`-based write-propagation confirmation
    /// (added alongside this fix) actually observes it — unlike the GDK
    /// path, which never fired that signal at all in the same repro.
    ///
    /// Returns `false` (never crashes/throws) whenever the extension isn't
    /// installed/active (`currentCapabilities.supports(.clipboard)` is
    /// `false`, `setClipboard`'s own existing guard) or the pipe write
    /// fails — callers fall back to their own non-privileged write path,
    /// exactly `GTKClipboardWriting`'s existing behavior today.
    public func setClipboardText(_ text: String) -> Bool {
      var fds: [Int32] = [0, 0]
      guard fds.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else { return false }
      let (readEnd, writeEnd) = (fds[0], fds[1])
      defer { Self.closeLeakedFileDescriptor(readEnd) }

      let bytes = Array(text.utf8)
      let wroteAll = bytes.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return true }
        return Glibc.write(writeEnd, base, buffer.count) == buffer.count
      }
      Glibc.close(writeEnd)
      guard wroteAll else { return false }

      return setClipboard(mimetype: "text/plain;charset=utf-8", fileDescriptor: readEnd) != nil
    }
  #else
    public func setClipboardText(_ text: String) -> Bool { false }
  #endif
}
