import ClipnestPlatformLinux
import Foundation

/// Detects whether `org.freedesktop.portal.GlobalShortcuts` is reachable —
/// DETECTION ONLY, see `HotkeyBackend.globalShortcutsPortal`'s doc comment
/// for why the full session/`BindShortcuts` request-and-`Response`-signal
/// handshake is out of scope for this build: the portal requires GNOME
/// 47+, which is newer than both of this project's target releases
/// (22.04/24.04), so this tier is provably dead code on every machine this
/// app ships to today. Kept as a real, if narrow, detection so
/// `HotkeyBackendResolver` degrades correctly the instant it DOES exist
/// (a user on a rolling/newer distro, or once the target-release floor
/// moves) rather than hardcoding `false` forever.
enum GlobalShortcutsPortalName {
  static let busName = "org.freedesktop.portal.Desktop"
  static let objectPath = "/org/freedesktop/portal/desktop"
  static let interface = "org.freedesktop.portal.GlobalShortcuts"
}

enum GlobalShortcutsPortalClient {
  /// `true` only if the portal's bus name is owned AND introspection (a
  /// bare `Properties.GetAll` on the `GlobalShortcuts` interface — every
  /// portal interface exposes at least a `version` property) succeeds —
  /// a name owner alone doesn't prove THIS specific interface is
  /// implemented, since `org.freedesktop.portal.Desktop` hosts dozens of
  /// unrelated portals behind the one bus name.
  static func isAvailable(on connection: any DBusCalling, timeout: Duration) -> Bool {
    guard
      let ownerReply = connection.call(
        DBusStandardRequests.nameHasOwner(GlobalShortcutsPortalName.busName, serial: 90),
        timeout: timeout),
      DBusStandardResponses.parseBooleanReply(ownerReply) == true
    else { return false }

    let propertiesMessage = DBusMessage(
      type: .methodCall, serial: 91, path: GlobalShortcutsPortalName.objectPath,
      interface: FreedesktopPropertiesName.interface,
      member: FreedesktopPropertiesMember.getAll,
      destination: GlobalShortcutsPortalName.busName,
      body: [.string(GlobalShortcutsPortalName.interface)])
    guard let reply = connection.call(propertiesMessage, timeout: timeout) else { return false }
    return reply.type == .methodReturn
  }
}
