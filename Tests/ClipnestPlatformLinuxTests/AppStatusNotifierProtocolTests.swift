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

  @Test("GetGroupProperties(ids, propertyNames) decodes both arrays")
  func getGroupPropertiesDecodesIdsAndPropertyNames() {
    let message = call(
      interface: "com.canonical.dbusmenu", member: "GetGroupProperties",
      body: [.array([.int32(1), .int32(2)]), .array([.string("label")])])
    #expect(
      StatusNotifierRequest.decode(message)
        == .menuGetGroupProperties(ids: [1, 2], propertyNames: ["label"]))
  }

  @Test("GetGroupProperties with empty arrays decodes to empty ids/propertyNames, not unknown")
  func getGroupPropertiesDecodesEmptyArrays() {
    let message = call(
      interface: "com.canonical.dbusmenu", member: "GetGroupProperties",
      body: [.array([]), .array([])])
    #expect(
      StatusNotifierRequest.decode(message) == .menuGetGroupProperties(ids: [], propertyNames: []))
  }
}

@Suite("StatusNotifierRequests")
struct AppStatusNotifierRequestsTests {
  @Test(
    "registerStatusNotifierItem(itemBusName:) carries the CALLER-GIVEN bus name, not a hardcoded one"
  )
  func registerStatusNotifierItemCarriesGivenBusName() {
    let message = StatusNotifierRequests.registerStatusNotifierItem(
      itemBusName: ":1.87", serial: 1)
    #expect(message.destination == "org.kde.StatusNotifierWatcher")
    #expect(message.member == "RegisterStatusNotifierItem")
    #expect(message.body == [.string(":1.87")])
    // Regression guard for the bug this fixes: the argument must be
    // whatever identity the CALLER passes (a real connection's own unique
    // name), never a literal this module invents — see this function's
    // doc comment for why hardcoding `ClipnestControlName.busName` here
    // was wrong (a well-known name owned by an unrelated connection).
    #expect(message.body != [.string("app.clipnest.Clipnest")])
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
    // Regression guard for the P0 this fixes: the root's `properties`
    // field is ALWAYS empty (the root itself has no dbusmenu properties),
    // and MUST be typed `a{sv}`, not degrade to `ay` — see
    // `DBusValue.emptyArray`'s doc comment for the connection-fatal bug
    // this was.
    #expect(root[1] == .emptyArray(elementSignature: DBusElementSignature.stringVariantDictEntry))
    #expect(root[1].signatureCode == "a{sv}")

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
    // Regression guard: every leaf's own `children` is ALWAYS empty (this
    // app's menu is deliberately one level deep) and MUST be typed `av`,
    // not degrade to `ay` — the literal defect that disconnected real
    // `com.canonical.dbusmenu` clients mid-`GetLayout`.
    #expect(firstChild[2] == .emptyArray(elementSignature: DBusElementSignature.variant))
    #expect(firstChild[2].signatureCode == "av")
  }

  @Test("getLayoutReply with zero menu items still types the root's empty children array as av")
  func layoutWithNoItemsTypesChildrenAsAv() {
    let reply = DBusMenuLayoutBuilder.getLayoutReply(items: [])
    guard reply.count == 2, case .structure(let root) = reply[1], root.count == 3 else {
      Issue.record("expected (revision, (id, properties, children))")
      return
    }
    #expect(root[2] == .emptyArray(elementSignature: DBusElementSignature.variant))
    #expect(root[2].signatureCode == "av")
  }

  private static let threeItems = [
    DBusMenuItem(id: 1, label: "Open Clipnest"), DBusMenuItem(id: 2, label: "Settings…"),
    DBusMenuItem(id: 3, label: "Quit Clipnest"),
  ]

  @Test("getGroupPropertiesReply with empty ids returns every item (spec's 'empty means all')")
  func getGroupPropertiesReplyEmptyIdsReturnsEveryItem() {
    let reply = DBusMenuLayoutBuilder.getGroupPropertiesReply(
      items: Self.threeItems, ids: [], propertyNames: [])
    guard reply.count == 1, case .array(let entries) = reply[0] else {
      Issue.record("expected a single a(ia{sv}) array")
      return
    }
    #expect(entries.count == 3)
  }

  @Test("getGroupPropertiesReply with explicit ids returns only those items, each with its label")
  func getGroupPropertiesReplyFiltersByIds() {
    let reply = DBusMenuLayoutBuilder.getGroupPropertiesReply(
      items: Self.threeItems, ids: [2], propertyNames: [])
    guard reply.count == 1, case .array(let entries) = reply[0], entries.count == 1,
      case .structure(let entry) = entries[0], entry.count == 2, case .int32(let id) = entry[0],
      case .array(let properties) = entry[1],
      case .dictEntry(.string(let key), .variant(.string(let label)))? = properties.first
    else {
      Issue.record("expected exactly one (id, {label: ...}) entry for id 2")
      return
    }
    #expect(id == 2)
    #expect(key == "label")
    #expect(label == "Settings…")
  }

  @Test("getGroupPropertiesReply with a non-'label' propertyNames filter returns empty properties")
  func getGroupPropertiesReplyFiltersOutUnrequestedProperties() {
    let reply = DBusMenuLayoutBuilder.getGroupPropertiesReply(
      items: Self.threeItems, ids: [1], propertyNames: ["icon-name"])
    guard reply.count == 1, case .array(let entries) = reply[0], entries.count == 1,
      case .structure(let entry) = entries[0], entry.count == 2
    else {
      Issue.record("expected exactly one (id, properties) entry")
      return
    }
    // A filtered-to-nothing properties dict is genuinely empty, and MUST
    // be typed `a{sv}`, not degrade to `ay` — the same defect class
    // `DBusValue.emptyArray`'s doc comment fixes for `GetLayout`.
    #expect(entry[1] == .emptyArray(elementSignature: DBusElementSignature.stringVariantDictEntry))
    #expect(entry[1].signatureCode == "a{sv}")
  }

  @Test("getGroupPropertiesReply with ids matching nothing types the outer array as a(ia{sv})")
  func getGroupPropertiesReplyWithNoMatchingIdsReturnsTypedEmptyArray() {
    let reply = DBusMenuLayoutBuilder.getGroupPropertiesReply(
      items: Self.threeItems, ids: [999], propertyNames: [])
    #expect(reply.count == 1)
    #expect(
      reply[0] == .emptyArray(elementSignature: DBusElementSignature.menuGroupPropertiesEntry))
    #expect(reply[0].signatureCode == "a(ia{sv})")
  }
}
