import Foundation

/// Every `org.freedesktop.DBus` (the bus daemon's own always-present
/// interface) bus name / object path / interface name / member name this
/// module uses — kept in ONE place per `coding-standards.md`'s "no magic
/// strings" rule. Mirrors `ClipnestPlatformLinux.ATSPIBusName`/
/// `ATSPIPath`/`ATSPIInterface`/`ATSPIMember`'s exact shape and naming
/// convention for the same interface, duplicated here (rather than
/// imported) only because that file's constants are `internal` to
/// `ClipnestPlatformLinux` and out of this module's scope to widen.
enum DBusStandardName {
  static let busServiceName = "org.freedesktop.DBus"
  static let busObjectPath = "/org/freedesktop/DBus"
  static let busInterface = "org.freedesktop.DBus"
}

enum DBusStandardMember {
  static let hello = "Hello"
  static let requestName = "RequestName"
  static let releaseName = "ReleaseName"
  static let nameHasOwner = "NameHasOwner"
  static let getNameOwner = "GetNameOwner"
  static let addMatch = "AddMatch"
  static let nameOwnerChanged = "NameOwnerChanged"
}

/// `RequestName`'s `flags` argument (D-Bus Specification, "Bus names").
/// This module only ever needs `DO_NOT_QUEUE` (single-instance: never wait
/// in line for a name another running Clipnest already owns) — the other
/// three documented flag bits (`ALLOW_REPLACEMENT`, `REPLACE_EXISTING`) are
/// deliberately absent since nothing here ever wants them.
enum DBusRequestNameFlag {
  static let doNotQueue: UInt32 = 0x4
}

/// `RequestName`'s `u` reply code (D-Bus Specification, "Bus names") — the
/// full set, even though `SingleInstanceDecision` only branches on
/// `.primaryOwner` vs. everything else, so a reply this module hasn't seen
/// before still decodes to a named case instead of silently falling through
/// as an unrecognized raw integer.
enum DBusRequestNameReply: UInt32, Equatable, Sendable {
  case primaryOwner = 1
  case inQueue = 2
  case exists = 3
  case alreadyOwner = 4
}
