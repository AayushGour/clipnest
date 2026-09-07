import ClipnestPlatformLinux
import Foundation

/// Pure builders/parsers for `org.kde.StatusNotifierWatcher` (registering
/// this app as a tray item) and the two interfaces this app then serves —
/// `org.kde.StatusNotifierItem` and `com.canonical.dbusmenu`. Mirrors
/// every other `*Requests`/`*Responses` pair in this directory.
enum StatusNotifierRequests {
  /// `RegisterStatusNotifierItem(s)` — per the StatusNotifierItem spec,
  /// `itemBusName` must identify the connection that actually HOSTS the
  /// item at the standard `/StatusNotifierItem` path (`StatusNotifierItemName
  /// .objectPath`), so the watcher knows where to send `Activate`/
  /// `ContextMenu`/`Properties.Get`/... back to. `StatusNotifierTray`
  /// serves that interface on `ownConnection`, which owns no well-known
  /// bus name of its own — so callers pass `ownConnection.uniqueName`
  /// (the `":1.N"` the daemon assigned it in reply to `Hello`), never a
  /// name owned by some OTHER connection.
  ///
  /// **Previously wrong:** this hardcoded `ClipnestControlName.busName`
  /// ("app.clipnest.Clipnest"), the well-known name `SingleInstance
  /// .acquire`'s `controlConnection` owns — a completely different
  /// connection that never serves `org.kde.StatusNotifierItem` at all. A
  /// watcher honoring that registration would query a bus name that
  /// exists but has nothing at `/StatusNotifierItem`, so even with `Hello`
  /// fixed the tray icon still would not have worked.
  static func registerStatusNotifierItem(itemBusName: String, serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: StatusNotifierWatcherName.objectPath,
      interface: StatusNotifierWatcherName.interface,
      member: StatusNotifierWatcherMember.registerStatusNotifierItem,
      destination: StatusNotifierWatcherName.busName, body: [.string(itemBusName)]
    )
  }
}

/// What incoming request `StatusNotifierTray` received, decoded from the
/// raw `DBusMessage` — covers both interfaces it serves
/// (`org.kde.StatusNotifierItem` and `com.canonical.dbusmenu`), since both
/// live at the same bus name and are dispatched through the one receive
/// loop.
enum StatusNotifierRequest: Equatable {
  case activate
  case secondaryActivate
  case contextMenu
  case getProperty(String)
  case getAllProperties
  case menuGetLayout
  case menuAboutToShow
  case menuEvent(itemID: Int32, eventID: String)
  /// `GetGroupProperties(ids, propertyNames)` — see `DBusMenuMember
  /// .getGroupProperties`'s doc comment for why real hosts call this.
  case menuGetGroupProperties(ids: [Int32], propertyNames: [String])
  /// `org.freedesktop.DBus.Introspectable.Introspect()` — carries
  /// `message.path` so the reply can describe the actual object being
  /// introspected (`StatusNotifierReplies.introspect(path:replyingTo:)`
  /// dispatches on it). See `StatusNotifierIntrospection`'s doc comment
  /// for the T-WB2 hang this fixes: every real tray object must answer
  /// this, never silently drop it.
  case introspect(path: String?)
  /// An interface/member this tray doesn't implement at all — maps to
  /// `org.freedesktop.DBus.Error.UnknownMethod`
  /// (`StatusNotifierReplies.unknownMethod(replyingTo:)`), mirroring
  /// `ClipnestControlRequest.unknown`'s own contract exactly. **Must
  /// never map to a silent (`nil`) reply** — a D-Bus method call with no
  /// reply and no error is indistinguishable from a hung process to the
  /// caller (T-WB2).
  case unknown

  static func decode(_ message: DBusMessage) -> StatusNotifierRequest? {
    guard message.type == .methodCall else { return nil }

    switch message.interface {
    case FreedesktopIntrospectableName.interface:
      guard message.member == FreedesktopIntrospectableMember.introspect else { return .unknown }
      return .introspect(path: message.path)
    case StatusNotifierItemName.interface:
      switch message.member {
      case StatusNotifierItemMember.activate: return .activate
      case StatusNotifierItemMember.secondaryActivate: return .secondaryActivate
      case StatusNotifierItemMember.contextMenu: return .contextMenu
      default: return .unknown
      }
    case DBusMenuName.interface:
      switch message.member {
      case DBusMenuMember.getLayout: return .menuGetLayout
      case DBusMenuMember.aboutToShow: return .menuAboutToShow
      case DBusMenuMember.event:
        guard message.body.count >= 2, case .int32(let itemID) = message.body[0],
          case .string(let eventID) = message.body[1]
        else { return .unknown }
        return .menuEvent(itemID: itemID, eventID: eventID)
      case DBusMenuMember.getGroupProperties:
        guard message.body.count >= 2, case .array(let idValues) = message.body[0],
          case .array(let nameValues) = message.body[1]
        else { return .unknown }
        let ids = idValues.compactMap { value -> Int32? in
          guard case .int32(let id) = value else { return nil }
          return id
        }
        let propertyNames = nameValues.compactMap { value -> String? in
          guard case .string(let name) = value else { return nil }
          return name
        }
        return .menuGetGroupProperties(ids: ids, propertyNames: propertyNames)
      default: return .unknown
      }
    case FreedesktopPropertiesName.interface:
      // KNOWN GAP, found verifying this task's `Hello`/identity fix against
      // a real watcher, NOT fixed here: this switch never looks at
      // `message.path`, so a `Properties.Get`/`GetAll` aimed at
      // `/app/clipnest/TrayMenu` (which should answer `com.canonical
      // .dbusmenu`'s OWN properties — `Version`/`TextDirection`/`Status`/
      // `IconThemePath`) is decoded identically to one aimed at
      // `/StatusNotifierItem` and answered with the SNI item's properties
      // instead (`StatusNotifierReplies.allProperties`/`.property(named:)`
      // both only know `StatusNotifierItemProperty` names). Confirmed live:
      // a real `gnome-panel` `IndicatorAppletComplete` widget calls
      // `Properties.GetAll` on `/app/clipnest/TrayMenu` and gets back
      // `Category`/`Id`/`Title`/... instead of the dbusmenu properties it
      // asked for. Fixing it needs `message.path` threaded into this
      // decode (and a small `DBusMenuProperties` reply builder) — out of
      // this task's assigned scope (Hello/identity/`GetGroupProperties`);
      // flagged for whoever owns this file next.
      switch message.member {
      case FreedesktopPropertiesMember.get:
        guard message.body.count == 2, case .string(let property) = message.body[1] else {
          return .unknown
        }
        return .getProperty(property)
      case FreedesktopPropertiesMember.getAll: return .getAllProperties
      default: return .unknown
      }
    default:
      return .unknown
    }
  }
}

enum StatusNotifierReplies {
  static func empty(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender)
  }

  static func property(named name: String, replyingTo message: DBusMessage) -> DBusMessage? {
    guard let value = propertyValue(named: name) else { return nil }
    return DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.variant(value)])
  }

  static func allProperties(replyingTo message: DBusMessage) -> DBusMessage {
    let entries = allPropertyNames.compactMap { name -> DBusValue? in
      propertyValue(named: name).map { .dictEntry(.string(name), .variant($0)) }
    }
    return DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.array(entries)])
  }

  static func menuLayout(items: [DBusMenuItem], replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: DBusMenuLayoutBuilder.getLayoutReply(items: items))
  }

  static func menuAboutToShowResult(needsUpdate: Bool, replyingTo message: DBusMessage)
    -> DBusMessage
  {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.boolean(needsUpdate)])
  }

  static func menuGroupProperties(
    items: [DBusMenuItem], ids: [Int32], propertyNames: [String], replyingTo message: DBusMessage
  ) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: DBusMenuLayoutBuilder.getGroupPropertiesReply(
        items: items, ids: ids, propertyNames: propertyNames))
  }

  /// `Introspect()`'s reply — see `StatusNotifierIntrospection`'s doc
  /// comment for why every exported object path must answer this (T-WB2).
  static func introspect(path: String?, replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .methodReturn, serial: 0, replySerial: message.serial, destination: message.sender,
      body: [.string(StatusNotifierIntrospection.xml(forPath: path))])
  }

  /// `org.freedesktop.DBus.Error.UnknownMethod` — the proper D-Bus error
  /// reply for a genuinely unimplemented interface/member, mirroring
  /// `ClipnestControlReplies.unknownMethod(replyingTo:)` exactly (same
  /// error name, same message shape). **Never `nil`** — see
  /// `StatusNotifierRequest.unknown`'s doc comment for why a silent drop
  /// is a D-Bus Specification violation (T-WB2).
  static func unknownMethod(replyingTo message: DBusMessage) -> DBusMessage {
    DBusMessage(
      type: .error, serial: 0, errorName: StatusNotifierErrorName.unknownMethod,
      replySerial: message.serial, destination: message.sender,
      body: [.string("No such member '\(message.member ?? "?")' on '\(message.interface ?? "?")'")]
    )
  }

  private static let allPropertyNames = [
    StatusNotifierItemProperty.category, StatusNotifierItemProperty.id,
    StatusNotifierItemProperty.title, StatusNotifierItemProperty.status,
    StatusNotifierItemProperty.iconName, StatusNotifierItemProperty.menu,
  ]

  private static func propertyValue(named name: String) -> DBusValue? {
    switch name {
    case StatusNotifierItemProperty.category: return .string(StatusNotifierItemValue.category)
    case StatusNotifierItemProperty.id: return .string(StatusNotifierItemValue.id)
    case StatusNotifierItemProperty.title: return .string(StatusNotifierItemValue.title)
    case StatusNotifierItemProperty.status: return .string(StatusNotifierItemValue.status)
    case StatusNotifierItemProperty.iconName: return .string(StatusNotifierItemValue.iconName)
    case StatusNotifierItemProperty.menu: return .objectPath(DBusMenuName.objectPath)
    default: return nil
    }
  }
}
