import ClipnestCore
import ClipnestPlatformLinux
import Foundation

/// The optional system tray icon: registers this app as a
/// `org.kde.StatusNotifierItem` with whatever `org.kde.StatusNotifierWatcher`
/// implementation the desktop runs (a GNOME Shell extension like
/// AppIndicator/KStatusNotifierItem, native on KDE/Xfce), and serves that
/// interface plus a minimal `com.canonical.dbusmenu` back to it — entirely
/// hand-rolled over this module's own `DBusConnection`, per the task's
/// explicit directive: **never link `libayatana-appindicator3`** (GTK3,
/// would pull a second GDK into this GTK4 process).
///
/// **Re-registration:** `org.kde.StatusNotifierWatcher` itself can restart
/// (a Shell extension providing it can be disabled/re-enabled, e.g. on
/// `gnome-shell --replace`) — this watches its `NameOwnerChanged` and
/// re-sends `RegisterStatusNotifierItem` every time a NEW owner appears,
/// so the tray icon survives a shell reload without this app restarting.
/// If no watcher exists at all (`NameHasOwner` false and it never
/// appears), this app simply runs with no tray — never a startup failure.
///
/// Manual-verify only — no session bus, no shell, no watcher in the CI
/// container this ships to; `StatusNotifierRequest.decode`/
/// `StatusNotifierReplies`/`DBusMenuLayoutBuilder` (the pure logic this
/// class is built from) are unit-tested directly instead.
///
/// **FIXED and re-verified against a real watcher (2026-09).** Two real,
/// previously-shipped bugs meant `registerIfWatcherPresent()` had NEVER
/// actually reached a real `org.kde.StatusNotifierWatcher`, in ANY
/// environment, independent of whether one existed:
/// 1. `ownConnection`/`watchConnection` (like every connection this app
///    ever opened) never sent the mandatory D-Bus `Hello` method, so a real
///    bus daemon rejected everything they sent with `AccessDenied`. Fixed
///    centrally, for every connection at once, inside
///    `ClipnestPlatformLinux.DBusConnection.connect(address:timeout:)` —
///    see that method's doc comment.
/// 2. `RegisterStatusNotifierItem` was called with `ClipnestControlName
///    .busName`, a well-known name owned by the unrelated `controlConnection`
///    (`SingleInstance.acquire`) — not by either connection this class
///    owns. Fixed: `registerIfWatcherPresent()`/the re-registration path in
///    `receiveLoop()` now pass `ownConnection.uniqueName` (the `":1.N"` the
///    daemon assigned `ownConnection` itself in reply to `Hello`) — see
///    `StatusNotifierRequests.registerStatusNotifierItem`'s doc comment.
///
/// Re-verified with BOTH fixed, against the real Ubuntu-Flashback tray
/// stack (`indicator-application-service` + `gnome-panel`, installed and
/// exercised for real, not assumed): `dbus-monitor` shows every connection
/// sending `Hello` and getting a real unique name; `RegisterStatusNotifierItem`
/// now carries `ownConnection`'s own name; the watcher accepts it (clean
/// `METHOD_RETURN`, no error) and its OWN live `RegisteredStatusNotifierItems`
/// property lists our item; a real client's `org.freedesktop.DBus
/// .Properties.GetAll` sent DIRECTLY to `ownConnection` succeeds with the
/// correct data (`Category`/`Id`/`Title`/`Status`/`IconName` =
/// `"app.clipnest.Clipnest-symbolic"`/`Menu`); a real client's
/// `com.canonical.dbusmenu.GetGroupProperties` call also succeeds, returning
/// the correct 3-item menu with correct labels end to end over a real bus.
///
/// **`GetLayout`'s connection-fatal disconnect is FIXED and the tray icon
/// now genuinely renders (2026-09) — see `debian/README.source`'s "Known
/// gap #4" for the full write-up.** Two real bugs, both in
/// `ClipnestPlatformLinux`'s wire layer, combined to kill `ownConnection`
/// mid-`GetLayout`:
/// 1. `DBusValue.array([]).signatureCode` degraded EVERY genuinely empty
///    array to `"ay"` — `GetLayout`'s root `properties: a{sv}` and every
///    leaf's `children: av` are always empty (this app's menu is
///    deliberately one level deep), so the reply's declared signature
///    claimed `"ay"` where a real `com.canonical.dbusmenu` client
///    expected `"av"`/`"a{sv}"`. Fixed by a dedicated
///    `DBusValue.emptyArray(elementSignature:)` case that carries its
///    true element type explicitly — see that case's own doc comment.
/// 2. Found while proving fix #1 with a real, non-empty byte-level
///    `GetLayout` round trip (not just a `DBusValue`-shape check):
///    `DBusByteWriter` marshalled an array's elements into an ISOLATED
///    sub-buffer and aligned only the SPLICE POINT to the array's
///    element type's own alignment — correct for `STRUCT`/`DICT_ENTRY`
///    (whose alignment, 8, is the D-Bus ceiling) but wrong for `VARIANT`
///    (declared alignment 1, yet `GetLayout`'s `av` children wrap a
///    `STRUCT`), so the wrapped struct's 8-byte alignment was computed
///    against a LOCAL offset that didn't reliably match the true global
///    one — silently shifting every field after it whenever the splice
///    point wasn't already 8-aligned by coincidence. Fixed by writing
///    array elements directly into the running buffer (backpatching the
///    length prefix afterward) instead of an isolated one — see
///    `DBusByteWriter`'s own doc comment.
///
/// **Re-verified end to end against a real bus** (`packaging/linux/vnc
/// /Dockerfile`-built `.deb`, the same Ubuntu-Flashback `indicator
/// -application-service` + `gnome-panel` stack): `dbus-send
/// com.canonical.dbusmenu.GetLayout` against the real running `clipnest`
/// returns a clean `METHOD_RETURN` (repeatable — the connection stays
/// alive across multiple calls), `gnome-panel`'s own log is free of
/// `LIBDBUSMENU-GLIB-WARNING`, and — the thing nobody had ever actually
/// seen — **the tray icon itself renders in the real panel.** Clicking it
/// opens the real `com.canonical.dbusmenu` context menu with all 3 items
/// correctly labeled; "Open Clipnest" opens the real picker (populated
/// with the session's actual clipboard history) and "Settings…" opens
/// the real Settings window, both proven live against the real running
/// process; "Quit Clipnest" cleanly exits it.
public final class StatusNotifierTray: @unchecked Sendable {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "StatusNotifierTray")

  private let ownConnection: DBusConnection
  private let watchConnection: DBusConnection?
  private var receiveThread: Thread?
  private let menuItems: [DBusMenuItem]

  public var onOpenClipnest: () -> Void = {}
  public var onOpenSettings: () -> Void = {}
  public var onQuit: () -> Void = {}

  public init(ownConnection: DBusConnection, watchConnection: DBusConnection?) {
    self.ownConnection = ownConnection
    self.watchConnection = watchConnection
    self.menuItems = [
      DBusMenuItem(id: DBusMenuItemID.openClipnest, label: "Open Clipnest"),
      DBusMenuItem(id: DBusMenuItemID.openSettings, label: "Settings…"),
      DBusMenuItem(id: DBusMenuItemID.quit, label: "Quit Clipnest"),
    ]
  }

  /// Attempts registration once, starts the receive loop regardless (so a
  /// watcher that appears LATER is still picked up via
  /// `watchConnection`'s `NameOwnerChanged` subscription), and never
  /// throws — a missing/refused watcher degrades to "no tray," per this
  /// task's reality check.
  public func start() {
    registerIfWatcherPresent()

    if let watchConnection {
      _ = watchConnection.call(
        DBusStandardRequests.addNameOwnerChangedMatch(
          forName: StatusNotifierWatcherName.busName, serial: 40), timeout: .milliseconds(250))
    }

    let thread = Thread { [weak self] in self?.receiveLoop() }
    thread.name = "StatusNotifierTray"
    receiveThread = thread
    thread.start()
  }

  private func registerIfWatcherPresent() {
    // `ownConnection.uniqueName` is set unconditionally by
    // `DBusConnection.connect(address:timeout:)`'s mandatory `Hello` — see
    // that property's doc comment for why this is effectively never `nil`
    // in practice; guarded anyway so a future connection-construction path
    // that somehow bypassed `connect` degrades to "no tray" rather than
    // registering an unidentifiable item.
    guard let watchConnection, let itemBusName = ownConnection.uniqueName else { return }
    let hasOwnerReply = watchConnection.call(
      DBusStandardRequests.nameHasOwner(StatusNotifierWatcherName.busName, serial: 41),
      timeout: .milliseconds(250))
    guard hasOwnerReply.flatMap(DBusStandardResponses.parseBooleanReply) == true else { return }
    _ = watchConnection.call(
      StatusNotifierRequests.registerStatusNotifierItem(itemBusName: itemBusName, serial: 42),
      timeout: .milliseconds(250))
  }

  private func receiveLoop() {
    // Same T-LX1-class diagnostic `ClipnestControlService.receiveLoop()`
    // carries — proof this loop is actually alive; see
    // `LinuxAppLifecycle`'s "Process-lifetime ownership" doc comment for
    // why this class needed the identical retention fix.
    Self.logger.info("tray D-Bus receive loop started")
    while true {
      if let watchConnection, let itemBusName = ownConnection.uniqueName,
        let ownerChange = watchConnection.receiveOneMessage(timeout: .milliseconds(50)),
        DBusStandardResponses.parseNameOwnerChanged(ownerChange)?.name
          == StatusNotifierWatcherName.busName,
        DBusStandardResponses.parseNameOwnerChanged(ownerChange)?.newOwner.isEmpty == false
      {
        _ = watchConnection.call(
          StatusNotifierRequests.registerStatusNotifierItem(itemBusName: itemBusName, serial: 43),
          timeout: .milliseconds(250))
      }

      guard let message = ownConnection.receiveOneMessage(timeout: .seconds(1)) else { continue }
      guard let request = StatusNotifierRequest.decode(message) else { continue }
      var outgoing = handle(request, message: message)
      outgoing.serial = ownConnection.allocateSerial()
      ownConnection.send(outgoing)
    }
  }

  /// **Always produces a reply — never `nil`.** Returning `DBusMessage?`
  /// used to let the `.unknown` branch silently drop a call
  /// (`receiveLoop()`'s old `guard let reply = handle(...) else {
  /// continue }`); making the return type non-optional makes that class of
  /// regression a compile error instead of a runtime hang (T-WB2 — see
  /// `.unknown`'s own doc comment below for the real repro this fixes).
  func handle(_ request: StatusNotifierRequest, message: DBusMessage) -> DBusMessage {
    switch request {
    case .introspect(let path):
      return StatusNotifierReplies.introspect(path: path, replyingTo: message)
    case .activate:
      onOpenClipnest()
      return StatusNotifierReplies.empty(replyingTo: message)
    case .secondaryActivate, .contextMenu:
      return StatusNotifierReplies.empty(replyingTo: message)
    case .getProperty(let name):
      return StatusNotifierReplies.property(named: name, replyingTo: message)
        ?? StatusNotifierReplies.empty(replyingTo: message)
    case .getAllProperties:
      return StatusNotifierReplies.allProperties(replyingTo: message)
    case .menuGetLayout:
      return StatusNotifierReplies.menuLayout(items: menuItems, replyingTo: message)
    case .menuGetGroupProperties(let ids, let propertyNames):
      return StatusNotifierReplies.menuGroupProperties(
        items: menuItems, ids: ids, propertyNames: propertyNames, replyingTo: message)
    case .menuAboutToShow:
      return StatusNotifierReplies.menuAboutToShowResult(needsUpdate: false, replyingTo: message)
    case .menuEvent(let itemID, let eventID):
      guard eventID == DBusMenuEventID.clicked else {
        return StatusNotifierReplies.empty(replyingTo: message)
      }
      switch itemID {
      case DBusMenuItemID.openClipnest: onOpenClipnest()
      case DBusMenuItemID.openSettings: onOpenSettings()
      case DBusMenuItemID.quit: onQuit()
      default: break
      }
      return StatusNotifierReplies.empty(replyingTo: message)
    case .unknown:
      // T-WB2 FIX: this used to return `nil`, which `receiveLoop()`'s
      // `guard let reply = handle(...) else { continue }` turned into a
      // silent drop — no reply, no error, indistinguishable from a hung
      // process to the caller. `org.freedesktop.DBus.Introspectable
      // .Introspect` decoded to exactly this case (it matched none of
      // `StatusNotifierRequest.decode`'s interface cases before
      // `.introspect` existed) and reproducibly hung a real `dbus-send`
      // against this object's real running process — see
      // `AppStatusNotifierTrayDispatchTests.swift`'s regression pin. Every
      // genuinely unrecognized method now gets a proper
      // `UnknownMethod` error instead, mirroring
      // `ClipnestControlDispatcher.handle`'s own `.unknown` case exactly.
      return StatusNotifierReplies.unknownMethod(replyingTo: message)
    }
  }
}
