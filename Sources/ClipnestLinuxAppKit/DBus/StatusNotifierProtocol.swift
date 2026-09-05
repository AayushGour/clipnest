import ClipnestPlatformLinux
import Foundation

/// Pure builders/parsers for `org.kde.StatusNotifierWatcher` (registering
/// this app as a tray item) and the two interfaces this app then serves —
/// `org.kde.StatusNotifierItem` and `com.canonical.dbusmenu`. Mirrors
/// every other `*Requests`/`*Responses` pair in this directory.
enum StatusNotifierRequests {
  /// `RegisterStatusNotifierItem(s)` — the argument is THIS app's own
  /// well-known bus name (`ClipnestControlName.busName`), the convention
  /// every StatusNotifierItem host recognizes for "the item lives on the
  /// sender's bus name at the standard `/StatusNotifierItem` path,"
  /// avoiding a second round trip to ask where it is.
  static func registerStatusNotifierItem(serial: UInt32) -> DBusMessage {
    DBusMessage(
      type: .methodCall, serial: serial, path: StatusNotifierWatcherName.objectPath,
      interface: StatusNotifierWatcherName.interface,
      member: StatusNotifierWatcherMember.registerStatusNotifierItem,
      destination: StatusNotifierWatcherName.busName, body: [.string(ClipnestControlName.busName)]
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
  case unknown

  static func decode(_ message: DBusMessage) -> StatusNotifierRequest? {
    guard message.type == .methodCall else { return nil }

    switch message.interface {
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
      default: return .unknown
      }
    case FreedesktopPropertiesName.interface:
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
