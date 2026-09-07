import CXlib
import Foundation
import Glibc

/// **UNVERIFIABLE WITHOUT A LIVE X SERVER — see this task's report.** The
/// one file in this module that calls Xlib/XFixes on Clipnest's OWN,
/// dedicated `Display*` connection. Every other file under `Clipboard/` is
/// pure logic, unit-tested with a fake conformance of
/// `X11SelectionConnecting`/`X11WindowIdentityQuerying`; this file is that
/// seam's real, production implementation, and is deliberately kept small
/// and isolated so as little logic as possible lives somewhere no CI
/// runner can exercise it (there is no X server in CI or in a container).
/// Compiled and lint-checked on every Linux CI run; never executed by any
/// test.
///
/// **This is NOT the only code in the process watching the CLIPBOARD
/// selection.** GTK4's own X11 backend (`gdk/x11/gdkclipboard-x11.c`)
/// unconditionally opens a SEPARATE, independent XFixes-based watch on
/// both `CLIPBOARD` and `PRIMARY` the moment `_gdk_x11_display_open` runs
/// — i.e. the instant `ClipnestGTKApplication.initializeGTK()` calls
/// `gtk_init()`, before any Clipnest code (this file included) gets
/// control, and with no supported GDK/GTK API, `GDK_DEBUG`/`GDK_DISABLE`
/// flag, or environment toggle to opt out of it — confirmed by reading
/// the actual Ubuntu 22.04 `gtk4` source (`gdk/x11/gdkdisplay-x11.c`,
/// `_gdk_x11_display_open`: `display->clipboard = gdk_x11_clipboard_new
/// (display, "CLIPBOARD")` runs unconditionally for every X11 display).
/// GTK's tracker fully duplicates the ownership-change/TARGETS-negotiation
/// work this file already does, entirely on its own, for reasons that
/// have nothing to do with whether Clipnest ever calls a GDK clipboard
/// API (GTK needs it for e.g. `GtkText`'s built-in "Paste" sensitivity).
/// That independent tracker is where the P0 `SIGSEGV` this class's git
/// history references actually happens: GTK 4.6.x's own
/// `gdk_x11_clipboard_request_targets_got_stream` calls the NULL-unsafe
/// `g_str_equal(type, "ATOM")` instead of the NULL-safe `g_strcmp0`
/// (confirmed fixed upstream by that exact substitution in later GTK)
/// against a `type` that CAN legitimately be `NULL` — whenever ANY
/// external process's ICCCM selection-reply property doesn't land where
/// GDK expects it (reproduced 100% with a raw python-xlib TARGETS owner
/// that writes its reply onto its OWN window instead of the requestor's —
/// no malice required, just a common ICCCM implementation slip in
/// whatever process happens to own `CLIPBOARD`). There are zero
/// Clipnest/Swift frames in that crash's stack because the fault is
/// entirely inside GTK/GLib's own async `GTask` completion, dispatched
/// from the GLib main loop — unreachable from and unfixable by any code
/// in this module or in `ClipnestGTKApplication.swift`'s GTK
/// initialization; the real fix is a GTK4 runtime-dependency version
/// bump (Ubuntu 22.04's own archives top out at the affected 4.6.9, so
/// this needs a backport/PPA — a packaging-level decision, tracked
/// separately, not a code change this module can make). `X11State
/// .readProperty`'s `actualType != Self.zero` guard exists so that THIS
/// file's own, independently-implemented equivalent of the same ICCCM
/// read cannot hit the analogous fault (it can't SIGSEGV in Swift either
/// way, but without the guard it silently misreported "property doesn't
/// exist" as "empty payload").
///
/// **Concurrency model:** one dedicated background `Thread` (`eventThread`)
/// owns the `Display*` connection for its entire lifetime and is the ONLY
/// thread that ever calls `XNextEvent`/`XPending` — required because
/// Xlib's event queue is a single shared FIFO per `Display`, and whichever
/// thread dequeues an event "gets" it, `SelectionNotify` included; a second
/// thread blocked in `XConvertSelection`'s implicit wait would only ever
/// see events some OTHER thread already stole. A synchronous conversion
/// request (`payload(forMimeType:)`, called from `ClipboardMonitor`'s
/// `@MainActor`) therefore hands its request to the event thread via
/// `pendingConversion` (guarded by `conversionCondition`) and blocks on
/// that condition variable until the event thread's own event-loop
/// iteration resolves it — either a plain `SelectionNotify` reply, or a
/// full ICCCM 2.7.2 INCR chunk sequence reassembled by
/// `IncrTransferReassembler`.
///
/// A single `NSLock` (`stateLock`) additionally guards the cached-targets/
/// serial bookkeeping that both the event thread (writer) and arbitrary
/// calling threads (readers, via `currentTargets()`/`changeSerial`) touch.
public final class X11ClipboardConnection: X11SelectionConnecting, X11WindowIdentityQuerying,
  @unchecked Sendable
{
  public static let shared = X11ClipboardConnection()

  /// Everything that depends on a successfully-opened `Display*` — `nil`
  /// end-to-end (every method below degrades to an empty/`nil` result,
  /// matching `PasteboardReading`'s existing "absent content" contract)
  /// when no X server was reachable at construction time, e.g. no
  /// `DISPLAY` set, or running in a container/CI with no X server —
  /// exactly the environment this task's own verification runs in.
  private let x11: X11State?

  private let stateLock = NSLock()
  private let conversionCondition = NSCondition()

  /// Bumped exactly once per observed `XFixesSelectionNotify`, from the
  /// event thread only; read from any thread under `stateLock`.
  private var serial = 0
  private var cachedTargetsSerial = -1
  private var cachedTargets: [String] = []

  private var pendingConversion: PendingConversion?

  public var onSelectionChanged: (@Sendable (Int, Bool) -> Void)?

  private init() {
    self.x11 = X11State()
    guard let x11 else { return }
    let thread = Thread { [weak self] in
      self?.runEventLoop(x11)
    }
    thread.name = "com.clipnest.linux.x11-clipboard"
    thread.start()
  }

  // MARK: - X11SelectionConnecting

  public var changeSerial: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return serial
  }

  public func currentTargets() -> [String] {
    guard let x11 else { return [] }

    stateLock.lock()
    let currentSerial = serial
    if cachedTargetsSerial == currentSerial {
      let cached = cachedTargets
      stateLock.unlock()
      return cached
    }
    stateLock.unlock()

    var targets: [String] = []
    if let rawData = requestConversion(x11, mimeType: LinuxClipboardConstants.targetsAtomName) {
      let atomIDs = Self.words(from: [UInt8](rawData))
      let names = atomIDs.compactMap { x11.atomName(for: Atom($0)) }
      targets = IgnoredTargetsFilter.filter(names)
    }

    stateLock.lock()
    cachedTargets = targets
    cachedTargetsSerial = currentSerial
    stateLock.unlock()
    return targets
  }

  public func payload(forMimeType mimeType: String) -> Data? {
    guard let x11 else { return nil }
    return requestConversion(x11, mimeType: mimeType)
  }

  // MARK: - X11WindowIdentityQuerying

  public func activeWindowID() -> UInt64? {
    guard let x11 else { return nil }
    guard
      let raw = x11.readProperty(
        window: x11.root, propertyName: LinuxClipboardConstants.netActiveWindowAtomName),
      raw.format == 32, let first = Self.words(from: raw.bytes).first
    else { return nil }
    return UInt64(first)
  }

  public func className(of window: UInt64) -> String? {
    guard let x11 else { return nil }
    guard
      let raw = x11.readProperty(
        window: Window(window), propertyName: LinuxClipboardConstants.wmClassAtomName)
    else { return nil }
    return WMClassParser.parse(raw.bytes)?.className
  }

  public func processID(of window: UInt64) -> Int32? {
    guard let x11 else { return nil }
    guard
      let raw = x11.readProperty(
        window: Window(window), propertyName: LinuxClipboardConstants.netWMPidAtomName),
      raw.format == 32, let first = Self.words(from: raw.bytes).first
    else { return nil }
    return Int32(truncatingIfNeeded: first)
  }

  public func gtkApplicationID(of window: UInt64) -> String? {
    guard let x11 else { return nil }
    guard
      let raw = x11.readProperty(
        window: Window(window), propertyName: LinuxClipboardConstants.gtkApplicationIDAtomName)
    else { return nil }
    return String(bytes: raw.bytes, encoding: .utf8)
  }

  public func windowName(of window: UInt64) -> String? {
    guard let x11 else { return nil }
    guard
      let raw = x11.readProperty(
        window: Window(window), propertyName: LinuxClipboardConstants.netWMNameAtomName)
    else { return nil }
    return String(bytes: raw.bytes, encoding: .utf8)
  }

  // MARK: - Conversion request/response (blocking, from any calling thread)

  private struct PendingConversion {
    var reassembler: IncrTransferReassembler?
    var incrStartedAt: TimeInterval = 0
    var resultData: Data?
    var isFinished = false
  }

  /// Blocks the calling thread until the event thread resolves this
  /// conversion (success, refusal, or timeout) — see this type's
  /// concurrency-model doc comment. Used identically for the `TARGETS`
  /// request (`currentTargets()`) and for a real content payload
  /// (`payload(forMimeType:)`) — both are just "convert this atom, read
  /// the (possibly INCR-chunked) reply property"; the two callers differ
  /// only in how they interpret the resulting bytes.
  private func requestConversion(_ x11: X11State, mimeType: String) -> Data? {
    let targetAtom = x11.internedAtom(mimeType)

    conversionCondition.lock()
    pendingConversion = PendingConversion()
    // `CurrentTime` (ICCCM/Xlib convention: 0) — see `X11State.zero`'s doc
    // comment for why this uses a self-typed zero instead of the macro.
    XConvertSelection(
      x11.display, x11.clipboardAtom, targetAtom, x11.replyPropertyAtom, x11.watcherWindow,
      Time(X11State.zero))
    XFlush(x11.display)

    let deadline = Date().addingTimeInterval(LinuxClipboardConstants.incrTransferTimeout)
    while pendingConversion?.isFinished != true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      _ = conversionCondition.wait(until: Date().addingTimeInterval(remaining))
    }
    let result = pendingConversion?.resultData
    pendingConversion = nil
    conversionCondition.unlock()
    return result
  }

  // MARK: - Event thread

  private func runEventLoop(_ x11: X11State) {
    while true {
      // Block (with a short ceiling, so a `stop()` in a future lifecycle
      // hook could interrupt this loop) until the X connection's fd is
      // readable, then drain every already-queued event before polling
      // again — avoids a busy loop while still noticing new events
      // promptly.
      var pfd = pollfd(fd: x11.connectionFileDescriptor, events: Int16(POLLIN), revents: 0)
      _ = poll(&pfd, 1, Int32(1_000))

      while XPending(x11.display) > 0 {
        var event = XEvent()
        XNextEvent(x11.display, &event)
        handle(event: &event, x11: x11)
      }
    }
  }

  private func handle(event: inout XEvent, x11: X11State) {
    if event.type == x11.xfixesSelectionNotifyEventType {
      handleXFixesSelectionNotify(&event, x11: x11)
      return
    }

    switch event.type {
    case Int32(SelectionNotify):
      handleSelectionNotify(event.xselection, x11: x11)
    case Int32(PropertyNotify):
      handlePropertyNotify(event.xproperty, x11: x11)
    default:
      break
    }
  }

  /// Fires on EVERY real CLIPBOARD ownership change — self-write or
  /// external — see `X11SelectionConnecting.onSelectionChanged`'s doc
  /// comment for the exact self-write-suppression contract this
  /// implements.
  private func handleXFixesSelectionNotify(_ event: inout XEvent, x11: X11State) {
    let fixesEvent = withUnsafePointer(to: &event) {
      $0.withMemoryRebound(to: XFixesSelectionNotifyEvent.self, capacity: 1) { $0.pointee }
    }
    let isSelfWrite = fixesEvent.owner == x11.watcherWindow

    stateLock.lock()
    serial += 1
    let newSerial = serial
    stateLock.unlock()

    onSelectionChanged?(newSerial, isSelfWrite)
  }

  private func handleSelectionNotify(_ event: XSelectionEvent, x11: X11State) {
    conversionCondition.lock()
    defer { conversionCondition.unlock() }
    guard var pending = pendingConversion else { return }

    // `property == None` (Xlib convention: 0) is ICCCM's "the owner
    // refused this conversion" — see `X11State.zero`'s doc comment.
    guard event.property != X11State.zero,
      let raw = x11.readAndDeleteProperty(
        window: x11.watcherWindow, propertyAtom: x11.replyPropertyAtom)
    else {
      pending.isFinished = true
      pendingConversion = pending
      conversionCondition.signal()
      return
    }

    if raw.type == x11.incrAtom {
      // ICCCM 2.7.2: the property we just deleted announced an upcoming
      // INCR transfer — the owner now sends the real chunks as further
      // property writes, acknowledged by deleting each one in turn (see
      // `handlePropertyNotify`).
      pending.reassembler = IncrTransferReassembler()
      pending.incrStartedAt = ProcessInfo.processInfo.systemUptime
      pendingConversion = pending
      return
    }

    pending.resultData = Data(raw.bytes)
    pending.isFinished = true
    pendingConversion = pending
    conversionCondition.signal()
  }

  private func handlePropertyNotify(_ event: XPropertyEvent, x11: X11State) {
    guard event.window == x11.watcherWindow, event.atom == x11.replyPropertyAtom,
      event.state == Int32(PropertyNewValue)
    else { return }

    conversionCondition.lock()
    defer { conversionCondition.unlock() }
    guard var pending = pendingConversion, var reassembler = pending.reassembler else { return }

    guard
      let raw = x11.readAndDeleteProperty(
        window: x11.watcherWindow, propertyAtom: x11.replyPropertyAtom)
    else {
      pending.isFinished = true
      pendingConversion = pending
      conversionCondition.signal()
      return
    }

    let elapsed = ProcessInfo.processInfo.systemUptime - pending.incrStartedAt
    do {
      if let complete = try reassembler.append(Data(raw.bytes), elapsedSinceTransferStart: elapsed)
      {
        pending.resultData = complete
        pending.isFinished = true
      } else {
        pending.reassembler = reassembler
        pendingConversion = pending
        return
      }
    } catch {
      // Timed out or exceeded the size ceiling — abort with no result,
      // matching this protocol's nil-on-failure contract.
      pending.isFinished = true
    }
    pendingConversion = pending
    conversionCondition.signal()
  }

  // MARK: - Byte-layout helpers

  /// Format-32 X11 properties are returned by `XGetWindowProperty` as
  /// native `unsigned long`-sized items (8 bytes each on a 64-bit Linux
  /// host), NOT 4-byte items, even though the wire protocol itself is
  /// 32-bit — a well-documented Xlib quirk. Used for `ATOM[]` (TARGETS),
  /// `WINDOW` (`_NET_ACTIVE_WINDOW`), and `CARDINAL` (`_NET_WM_PID`)
  /// properties alike.
  fileprivate static func words(from bytes: [UInt8]) -> [UInt] {
    let wordSize = MemoryLayout<UInt>.size
    guard bytes.count % wordSize == 0 else { return [] }
    return bytes.withUnsafeBytes { raw in
      Array(raw.bindMemory(to: UInt.self))
    }
  }
}
