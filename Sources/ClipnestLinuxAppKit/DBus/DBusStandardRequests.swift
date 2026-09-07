import ClipnestPlatformLinux
import Foundation

/// Pure builders for every `org.freedesktop.DBus` (the bus daemon itself)
/// method-call message this module ever sends — mirrors
/// `ClipnestPlatformLinux.ATSPIRequests`'s exact split (message
/// construction separated from the connection that sends it) so the wire
/// shape is directly unit-testable without a real bus.
///
/// **No `hello()` builder here, deliberately.** `Hello` used to be built
/// and sent from this module (`SingleInstance.acquire`, the only call site
/// that remembered to) — it now lives in `ClipnestPlatformLinux
/// .DBusConnection.connect(address:timeout:)`, sent unconditionally for
/// EVERY connection before it's ever returned to a caller, so no caller in
/// this module (or any other) can forget it again. See that method's doc
/// comment for why it moved and what a caller can now assume.
enum DBusStandardRequests {
  static func requestName(_ name: String, flags: UInt32, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: DBusStandardName.busObjectPath,
      interface: DBusStandardName.busInterface, member: DBusStandardMember.requestName,
      destination: DBusStandardName.busServiceName, body: [.string(name), .uint32(flags)])
  }

  static func nameHasOwner(_ name: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: DBusStandardName.busObjectPath,
      interface: DBusStandardName.busInterface, member: DBusStandardMember.nameHasOwner,
      destination: DBusStandardName.busServiceName, body: [.string(name)])
  }

  static func getNameOwner(_ name: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: DBusStandardName.busObjectPath,
      interface: DBusStandardName.busInterface, member: DBusStandardMember.getNameOwner,
      destination: DBusStandardName.busServiceName, body: [.string(name)])
  }

  /// The match rule that receives `NameOwnerChanged` for exactly `name` —
  /// scoped with `arg0=` so this connection isn't forwarded every OTHER
  /// service's ownership churn on a busy session bus. Used both for
  /// watching `app.clipnest.ShellHelper` (does enabling/disabling the
  /// extension take effect live) and, in principle, any other well-known
  /// name this module ever needs to watch.
  static func addNameOwnerChangedMatch(forName name: String, serial: UInt32) -> DBusMessage {
    let rule =
      "type='signal',sender='\(DBusStandardName.busServiceName)',"
      + "interface='\(DBusStandardName.busInterface)',member='\(DBusStandardMember.nameOwnerChanged)',"
      + "arg0='\(name)'"
    return DBusMessage(
      type: .methodCall, serial: serial, path: DBusStandardName.busObjectPath,
      interface: DBusStandardName.busInterface, member: DBusStandardMember.addMatch,
      destination: DBusStandardName.busServiceName, body: [.string(rule)])
  }
}

/// Pure parsers for every `org.freedesktop.DBus` reply/signal this module
/// ever reads.
enum DBusStandardResponses {
  static func parseUInt32Reply(_ message: DBusMessage) -> UInt32? {
    guard message.type == .methodReturn, case .uint32(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  static func parseRequestNameReply(_ message: DBusMessage) -> DBusRequestNameReply? {
    parseUInt32Reply(message).flatMap(DBusRequestNameReply.init(rawValue:))
  }

  static func parseBooleanReply(_ message: DBusMessage) -> Bool? {
    guard message.type == .methodReturn, case .boolean(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  static func parseStringReply(_ message: DBusMessage) -> String? {
    guard message.type == .methodReturn, case .string(let value)? = message.body.first else {
      return nil
    }
    return value
  }

  /// `NameOwnerChanged(name, old_owner, new_owner)` — `new_owner` is empty
  /// when the name was released with nobody left to own it.
  static func parseNameOwnerChanged(
    _ message: DBusMessage
  ) -> (name: String, oldOwner: String, newOwner: String)? {
    guard message.type == .signal, message.member == DBusStandardMember.nameOwnerChanged,
      message.body.count == 3, case .string(let name) = message.body[0],
      case .string(let oldOwner) = message.body[1], case .string(let newOwner) = message.body[2]
    else { return nil }
    return (name, oldOwner, newOwner)
  }
}
