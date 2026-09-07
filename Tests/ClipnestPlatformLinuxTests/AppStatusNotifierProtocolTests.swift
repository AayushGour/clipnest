import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

private func call(interface: String, member: String, body: [DBusValue] = []) -> DBusMessage {
  DBusMessage(
    type: .methodCall, serial: 1, path: "/StatusNotifierItem", interface: interface,
    member: member, sender: ":1.50", body: body)
}

@Suite("StatusNotifierRequest.decode")
struct AppStatusNotifierProtocolTests {
  @Test("Activate/SecondaryActivate/ContextMenu decode on org.kde.StatusNotifierItem")
  func itemMembersDecode() {
    #expect(
      StatusNotifierRequest.decode(
        call(interface: "org.kde.StatusNotifierItem", member: "Activate"))
        == .activate)
    #expect(
      StatusNotifierRequest.decode(
        call(interface: "org.kde.StatusNotifierItem", member: "SecondaryActivate"))
        == .secondaryActivate)
    #expect(
      StatusNotifierRequest.decode(
        call(interface: "org.kde.StatusNotifierItem", member: "ContextMenu")) == .contextMenu)
  }

  @Test("GetLayout/AboutToShow decode on com.canonical.dbusmenu")
  func menuMembersDecode() {
    #expect(
      StatusNotifierRequest.decode(call(interface: "com.canonical.dbusmenu", member: "GetLayout"))
        == .menuGetLayout)
    #expect(
      StatusNotifierRequest.decode(call(interface: "com.canonical.dbusmenu", member: "AboutToShow"))
        == .menuAboutToShow)
  }

  @Test("Event(itemID, eventID, ...) decodes the item id and event id")
  func eventDecodesItemAndEventID() {
    let message = call(
      interface: "com.canonical.dbusmenu", member: "Event",
      body: [.int32(3), .string("clicked"), .variant(.string("")), .uint32(0)])
    #expect(StatusNotifierRequest.decode(message) == .menuEvent(itemID: 3, eventID: "clicked"))
  }

  @Test("Properties.Get(property) decodes the queried property name")
  func propertiesGetDecodesPropertyName() {
    let message = call(
      interface: "org.freedesktop.DBus.Properties", member: "Get",
      body: [.string("org.kde.StatusNotifierItem"), .string("Title")])
    #expect(StatusNotifierRequest.decode(message) == .getProperty("Title"))
  }
}

@Suite("StatusNotifierReplies")
struct AppStatusNotifierRepliesTests {
  @Test("property(named:) resolves every documented SNI property")
  func propertyResolvesEveryDocumentedName() {
    let request = call(interface: "org.freedesktop.DBus.Properties", member: "Get")
    for name in ["Category", "Id", "Title", "Status", "IconName", "Menu"] {
      #expect(
        StatusNotifierReplies.property(named: name, replyingTo: request) != nil,
        "expected a value for \(name)")
    }
  }

  @Test("property(named:) returns nil for an unrecognized property")
  func propertyReturnsNilForUnknownName() {
    let request = call(interface: "org.freedesktop.DBus.Properties", member: "Get")
    #expect(StatusNotifierReplies.property(named: "NotARealProperty", replyingTo: request) == nil)
  }

  @Test("IconName resolves to the Clipnest-branded symbolic icon debian/rules installs")
  func iconNameIsTheClipnestBrandedSymbolicIcon() {
    let request = call(interface: "org.freedesktop.DBus.Properties", member: "Get")
    guard let reply = StatusNotifierReplies.property(named: "IconName", replyingTo: request),
      case .variant(.string(let iconName))? = reply.body.first
    else {
      Issue.record("expected IconName to resolve to a string variant")
      return
    }
    #expect(iconName == StatusNotifierItemValue.iconName)
    // Freedesktop convention: "-symbolic" is part of the icon NAME (not just
    // the installed filename) that hosts resolve via
    // hicolor/symbolic/apps/<name>.svg — never the generic
    // "edit-paste-symbolic" fallback this used to ship.
    #expect(iconName.hasSuffix("-symbolic"))
    #expect(iconName == "app.clipnest.Clipnest-symbolic")
  }

  @Test("allProperties() includes an entry for every documented property")
  func allPropertiesIncludesEveryName() {
    let request = call(interface: "org.freedesktop.DBus.Properties", member: "GetAll")
    let reply = StatusNotifierReplies.allProperties(replyingTo: request)
    guard case .array(let entries)? = reply.body.first else {
      Issue.record("expected a{sv}")
      return
    }
    #expect(entries.count == 6)
  }
}

@Suite("DBusMenuLayoutBuilder")
struct AppDBusMenuLayoutBuilderTests {
  @Test("getLayoutReply's root item id is the fixed root constant, with every leaf as a child")
  func layoutStructureIsCorrect() {
    let items = [
      DBusMenuItem(id: 1, label: "Open Clipnest"), DBusMenuItem(id: 2, label: "Quit Clipnest"),
    ]
    let reply = DBusMenuLayoutBuilder.getLayoutReply(items: items)
    guard reply.count == 2, case .uint32 = reply[0],
      case .structure(let root) = reply[1], root.count == 3, case .int32(let rootID) = root[0],
      case .array(let children) = root[2]
    else {
      Issue.record("expected (revision, (id, properties, children))")
      return
    }
    #expect(rootID == 0)
    #expect(children.count == 2)

    guard case .variant(.structure(let firstChild)) = children[0], firstChild.count == 3,
      case .int32(let firstID) = firstChild[0], case .array(let firstProperties) = firstChild[1]
    else {
      Issue.record("expected the first child as a variant<(id, properties, children)>")
      return
    }
    #expect(firstID == 1)
    guard case .dictEntry(.string(let key), .variant(.string(let label))) = firstProperties.first
    else {
      Issue.record("expected a label property")
      return
    }
    #expect(key == "label")
    #expect(label == "Open Clipnest")
  }
}
