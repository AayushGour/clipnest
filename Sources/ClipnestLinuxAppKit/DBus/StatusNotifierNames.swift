import Foundation

/// `org.kde.StatusNotifierWatcher` — the freedesktop/KDE tray-registration
/// service every StatusNotifierItem-hosting desktop (GNOME via an
/// extension, KDE, Xfce, ...) runs. This app registers ITSELF as an item
/// with it; it never watches other items.
enum StatusNotifierWatcherName {
  static let busName = "org.kde.StatusNotifierWatcher"
  static let objectPath = "/StatusNotifierWatcher"
  static let interface = "org.kde.StatusNotifierWatcher"
}

enum StatusNotifierWatcherMember {
  static let registerStatusNotifierItem = "RegisterStatusNotifierItem"
}

/// The interface THIS app exposes once registered — `org.kde.
/// StatusNotifierItem`, hosted at a fixed, well-known object path under
/// this app's own `ClipnestControlName.busName` (a tray item is
/// identified by `(service, objectPath)`, not a separate bus name).
enum StatusNotifierItemName {
  static let objectPath = "/StatusNotifierItem"
  static let interface = "org.kde.StatusNotifierItem"
}

enum StatusNotifierItemMember {
  static let activate = "Activate"
  static let secondaryActivate = "SecondaryActivate"
  static let contextMenu = "ContextMenu"
}

enum StatusNotifierItemProperty {
  static let category = "Category"
  static let id = "Id"
  static let title = "Title"
  static let status = "Status"
  static let iconName = "IconName"
  static let menu = "Menu"
}

/// This app's fixed `org.kde.StatusNotifierItem` property VALUES — one
/// place, per `coding-standards.md`'s "no magic strings" rule, rather than
/// re-spelled at every `Properties.Get`/`GetAll` reply site.
enum StatusNotifierItemValue {
  static let category = "ApplicationStatus"
  static let id = "app.clipnest.Clipnest"
  static let title = "Clipnest"
  static let status = "Active"
  /// The Clipnest-branded symbolic icon, derived from
  /// `assets/clipnest-icons/clipnest-mono.svg` (never redrawn — see that
  /// dir's README) and installed by `debian/rules` to
  /// `/usr/share/icons/hicolor/symbolic/apps/app.clipnest.Clipnest-symbolic.svg`.
  /// Per the freedesktop icon-naming convention (e.g. GNOME apps ship
  /// "org.foo.Bar-symbolic"), the `-symbolic` suffix is part of the NAME,
  /// not just the filename. `hicolor` is every icon theme's guaranteed
  /// fallback search path, so this resolves as long as the package is
  /// installed — no dependency on a specific desktop theme.
  static let iconName = "app.clipnest.Clipnest-symbolic"
}

/// `com.canonical.dbusmenu` — the menu THIS app exposes at
/// `StatusNotifierItemProperty.menu`'s object path.
enum DBusMenuName {
  static let objectPath = "/app/clipnest/TrayMenu"
  static let interface = "com.canonical.dbusmenu"
}

enum DBusMenuMember {
  static let getLayout = "GetLayout"
  static let aboutToShow = "AboutToShow"
  static let event = "Event"
  /// `GetGroupProperties(in ai ids, in as propertyNames, out a(ia{sv})
  /// properties)` — real `libdbusmenu-glib` clients (gnome-panel's
  /// `IndicatorAppletComplete` among them) call this right after
  /// `GetLayout`/`AboutToShow` to bulk-fetch item properties; leaving it
  /// unimplemented logs `LIBDBUSMENU-GLIB-WARNING: ... GetGroupProperties
  /// is not a valid method` on a real host and the menu renders empty.
  static let getGroupProperties = "GetGroupProperties"
}

enum DBusMenuProperty {
  static let label = "label"
}

enum DBusMenuEventID {
  static let clicked = "clicked"
}

/// This tray menu's fixed item identifiers — never re-derived, so
/// `StatusNotifierTray`'s `Event` handler and `DBusMenuLayoutBuilder`'s
/// `GetLayout` reply can never disagree about which id means what.
enum DBusMenuItemID {
  static let root: Int32 = 0
  static let openClipnest: Int32 = 1
  static let openSettings: Int32 = 2
  static let quit: Int32 = 3
}

/// `org.freedesktop.DBus.Introspectable` — every D-Bus object should answer
/// this (T-WB2: a real client that introspects before calling — `d-feet`,
/// `gdbus call`'s default discovery behavior, and some tray-host
/// implementations — hung forever against `StatusNotifierTray`'s object
/// paths because nothing here ever answered it; see `StatusNotifierRequest
/// .introspect`'s doc comment for the full repro). This module's own copy
/// of the interface name, mirroring `FreedesktopPropertiesName`'s shape.
enum FreedesktopIntrospectableName {
  static let interface = "org.freedesktop.DBus.Introspectable"
}

enum FreedesktopIntrospectableMember {
  static let introspect = "Introspect"
}

/// The one D-Bus error name this tray ever replies with — same fixed
/// string as `ClipnestControlErrorName.unknownMethod`
/// (`ClipnestControlProtocol.swift`) per the D-Bus Specification's error
/// vocabulary; kept as this file's own copy rather than imported, same
/// "duplicate across an ownership boundary" precedent `DBusStandardName`'s
/// own doc comment documents (that file mirrors `ATSPIBusName` for the
/// identical reason).
enum StatusNotifierErrorName {
  static let unknownMethod = "org.freedesktop.DBus.Error.UnknownMethod"
}
