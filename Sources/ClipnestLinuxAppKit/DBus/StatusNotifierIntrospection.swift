import Foundation

/// Pure builder for `org.freedesktop.DBus.Introspectable.Introspect`'s XML
/// reply body — one shape per object path this tray actually exports, so a
/// real introspecting client (`d-feet`, `gdbus call`'s default discovery,
/// and some tray-host implementations that introspect before calling)
/// finds the real interface at that path instead of nothing at all.
///
/// **T-WB2.** Before this existed, `StatusNotifierRequest.decode` had no
/// case for `Introspectable` at all — it fell through to `.unknown`, and
/// `StatusNotifierTray.handle`'s `.unknown` case returned `nil`, which
/// `receiveLoop()`'s `guard let reply = handle(...) else { continue }`
/// turned into a silent drop: no `METHOD_RETURN`, no `ERROR`, nothing sent
/// back. `dbus-send --print-reply .../StatusNotifierItem
/// org.freedesktop.DBus.Introspectable.Introspect` reproducibly hung
/// against a real running `clipnest` binary because of exactly this (see
/// `AppStatusNotifierTrayDispatchTests.swift`'s regression pin). Fixed by
/// giving `Introspect` its own decoded case (`StatusNotifierRequest
/// .introspect`) that always produces a real reply — this type builds
/// that reply's XML — and by making every OTHER unrecognized method
/// return a proper `org.freedesktop.DBus.Error.UnknownMethod` instead of
/// `nil`, mirroring `ClipnestControlDispatcher.handle`'s own `.unknown`
/// case (`ClipnestControlProtocol.swift`) exactly.
enum StatusNotifierIntrospection {
  /// `path` is `message.path` off the incoming `Introspect` call.
  /// `StatusNotifierItemName.objectPath` and `DBusMenuName.objectPath` are
  /// the only two object paths this tray actually serves, so those get
  /// their real methods/properties; anything else (this app exports no
  /// other object, but a client that walks the tree down from `/` could
  /// still ask about an intermediate node) gets the minimal, spec-legal
  /// stub that answers ONLY `Introspectable` itself — never silence.
  static func xml(forPath path: String?) -> String {
    let interfaceBlocks: [String]
    switch path {
    case StatusNotifierItemName.objectPath:
      interfaceBlocks = [introspectableInterface, propertiesInterface, statusNotifierItemInterface]
    case DBusMenuName.objectPath:
      interfaceBlocks = [introspectableInterface, propertiesInterface, dbusMenuInterface]
    default:
      interfaceBlocks = [introspectableInterface]
    }
    return "\(doctype)\n<node>\n\(interfaceBlocks.joined(separator: "\n"))\n</node>\n"
  }

  private static let doctype = """
    <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    """

  private static let introspectableInterface = """
      <interface name="\(FreedesktopIntrospectableName.interface)">
        <method name="\(FreedesktopIntrospectableMember.introspect)">
          <arg name="xml_data" type="s" direction="out"/>
        </method>
      </interface>
    """

  private static let propertiesInterface = """
      <interface name="\(FreedesktopPropertiesName.interface)">
        <method name="\(FreedesktopPropertiesMember.get)">
          <arg name="interface_name" type="s" direction="in"/>
          <arg name="property_name" type="s" direction="in"/>
          <arg name="value" type="v" direction="out"/>
        </method>
        <method name="\(FreedesktopPropertiesMember.getAll)">
          <arg name="interface_name" type="s" direction="in"/>
          <arg name="properties" type="a{sv}" direction="out"/>
        </method>
      </interface>
    """

  private static let statusNotifierItemInterface = """
      <interface name="\(StatusNotifierItemName.interface)">
        <method name="\(StatusNotifierItemMember.activate)">
          <arg name="x" type="i" direction="in"/>
          <arg name="y" type="i" direction="in"/>
        </method>
        <method name="\(StatusNotifierItemMember.secondaryActivate)">
          <arg name="x" type="i" direction="in"/>
          <arg name="y" type="i" direction="in"/>
        </method>
        <method name="\(StatusNotifierItemMember.contextMenu)">
          <arg name="x" type="i" direction="in"/>
          <arg name="y" type="i" direction="in"/>
        </method>
        <property name="\(StatusNotifierItemProperty.category)" type="s" access="read"/>
        <property name="\(StatusNotifierItemProperty.id)" type="s" access="read"/>
        <property name="\(StatusNotifierItemProperty.title)" type="s" access="read"/>
        <property name="\(StatusNotifierItemProperty.status)" type="s" access="read"/>
        <property name="\(StatusNotifierItemProperty.iconName)" type="s" access="read"/>
        <property name="\(StatusNotifierItemProperty.menu)" type="o" access="read"/>
      </interface>
    """

  private static let dbusMenuInterface = """
      <interface name="\(DBusMenuName.interface)">
        <method name="\(DBusMenuMember.getLayout)">
          <arg name="parentId" type="i" direction="in"/>
          <arg name="recursionDepth" type="i" direction="in"/>
          <arg name="propertyNames" type="as" direction="in"/>
          <arg name="revision" type="u" direction="out"/>
          <arg name="layout" type="(ia{sv}av)" direction="out"/>
        </method>
        <method name="\(DBusMenuMember.getGroupProperties)">
          <arg name="ids" type="ai" direction="in"/>
          <arg name="propertyNames" type="as" direction="in"/>
          <arg name="properties" type="a(ia{sv})" direction="out"/>
        </method>
        <method name="\(DBusMenuMember.aboutToShow)">
          <arg name="id" type="i" direction="in"/>
          <arg name="needUpdate" type="b" direction="out"/>
        </method>
        <method name="\(DBusMenuMember.event)">
          <arg name="id" type="i" direction="in"/>
          <arg name="eventId" type="s" direction="in"/>
          <arg name="data" type="v" direction="in"/>
          <arg name="timestamp" type="u" direction="in"/>
        </method>
      </interface>
    """
}
