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
    guard let watchConnection else { return }
    let hasOwnerReply = watchConnection.call(
      DBusStandardRequests.nameHasOwner(StatusNotifierWatcherName.busName, serial: 41),
      timeout: .milliseconds(250))
    guard hasOwnerReply.flatMap(DBusStandardResponses.parseBooleanReply) == true else { return }
    _ = watchConnection.call(
      StatusNotifierRequests.registerStatusNotifierItem(serial: 42), timeout: .milliseconds(250))
  }

  private func receiveLoop() {
    // Same T-LX1-class diagnostic `ClipnestControlService.receiveLoop()`
    // carries — proof this loop is actually alive; see
    // `LinuxAppLifecycle`'s "Process-lifetime ownership" doc comment for
    // why this class needed the identical retention fix.
    Self.logger.info("tray D-Bus receive loop started")
    while true {
      if let watchConnection,
        let ownerChange = watchConnection.receiveOneMessage(timeout: .milliseconds(50)),
        DBusStandardResponses.parseNameOwnerChanged(ownerChange)?.name
          == StatusNotifierWatcherName.busName,
        DBusStandardResponses.parseNameOwnerChanged(ownerChange)?.newOwner.isEmpty == false
      {
        _ = watchConnection.call(
          StatusNotifierRequests.registerStatusNotifierItem(serial: 43),
          timeout: .milliseconds(250))
      }

      guard let message = ownConnection.receiveOneMessage(timeout: .seconds(1)) else { continue }
      guard let request = StatusNotifierRequest.decode(message) else { continue }
      guard let reply = handle(request, message: message) else { continue }
      var outgoing = reply
      outgoing.serial = ownConnection.allocateSerial()
      ownConnection.send(outgoing)
    }
  }

  func handle(_ request: StatusNotifierRequest, message: DBusMessage) -> DBusMessage? {
    switch request {
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
      return nil
    }
  }
}
