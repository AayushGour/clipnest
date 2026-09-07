import Foundation

/// Every AT-SPI2/D-Bus bus name, object path, interface name, member name,
/// and timing constant this module uses — kept in ONE place per
/// coding-standards.md's "no magic strings/numbers" rule.
enum ATSPIBusName {
  /// The session-bus-resident service implementing `org.a11y.Bus` — its
  /// well-known bus name equals its main interface name, the usual D-Bus
  /// convention for a bus's own bootstrap service.
  static let a11yBusService = "org.a11y.Bus"
  /// `at-spi2-registryd`'s well-known name on the AT-SPI bus itself.
  static let registry = "org.a11y.atspi.Registry"
  /// The bus daemon's own always-present well-known name, used for
  /// `AddMatch`.
  static let dbusDaemon = "org.freedesktop.DBus"
}

enum ATSPIPath {
  static let bus = "/org/a11y/bus"
  static let registry = "/org/a11y/atspi/registry"
  static let dbusDaemon = "/org/freedesktop/DBus"
}

enum ATSPIInterface {
  static let bus = "org.a11y.Bus"
  static let status = "org.a11y.Status"
  static let text = "org.a11y.atspi.Text"
  static let editableText = "org.a11y.atspi.EditableText"
  static let registry = "org.a11y.atspi.Registry"
  static let event = "org.a11y.atspi.Event.Object"
  static let dbus = "org.freedesktop.DBus"
  static let properties = "org.freedesktop.DBus.Properties"
}

enum ATSPIMember {
  static let getAddress = "GetAddress"
  static let getNSelections = "GetNSelections"
  static let getSelection = "GetSelection"
  static let getText = "GetText"
  static let deleteText = "DeleteText"
  static let insertText = "InsertText"
  static let registerEvent = "RegisterEvent"
  static let addMatch = "AddMatch"
  static let stateChanged = "StateChanged"
  static let propertiesGet = "Get"
  /// `org.freedesktop.DBus.Hello` — every D-Bus client MUST send this,
  /// unconditionally, before any other traffic (D-Bus Specification, "The
  /// Hello method"); a real `dbus-daemon` rejects everything else with
  /// `AccessDenied` otherwise. Used by `DBusConnection.connect(address:
  /// timeout:)` (the ONE place this app ever sends it — see that method's
  /// doc comment for why it's centralized there and not per-caller), which
  /// reuses `ATSPIBusName.dbusDaemon`/`ATSPIPath.dbusDaemon`/
  /// `ATSPIInterface.dbus` below the exact same way `ATSPIRequests
  /// .addFocusMatch` already does — this trio names the bus daemon's own
  /// always-present `org.freedesktop.DBus` interface, not anything AT-SPI-
  /// specific, despite the `ATSPI*` prefix (this module's established home
  /// for it — see that enum's own doc comment).
  static let hello = "Hello"
}

/// The legacy AT-SPI `interface:signal:detail` event-name string this
/// module registers for — see `org.a11y.atspi.Registry.RegisterEvent`.
enum ATSPIEventName {
  static let focused = "object:state-changed:focused"
}

/// The `org.freedesktop.DBus.AddMatch` rule that receives every
/// `org.a11y.atspi.Event.Object.StateChanged` signal this connection is
/// forwarded — filtered further to just "focused" in
/// `ATSPIFocusEventParsing`, since `AddMatch` itself can't filter on a
/// signal's body contents, only its header fields.
enum ATSPIMatchRule {
  static let stateChanged =
    "interface='\(ATSPIInterface.event)',member='\(ATSPIMember.stateChanged)'"
}

/// The state name `StateChanged`'s first body argument carries when the
/// state in question is keyboard focus.
enum ATSPIStateName {
  static let focused = "focused"
}

/// `org.a11y.Status.IsEnabled`'s property name, read (never written — see
/// `AccessibilityBusResolver`'s doc comment) for diagnostics.
enum ATSPIProperty {
  static let isEnabled = "IsEnabled"
}

/// `public`: referenced as a default-argument value by `public` API
/// (`ATSPITextAccessor.init`, `AccessibilityBusResolver`'s methods), which
/// requires it be at least as visible as those.
public enum ATSPIConstants {
  /// Applied to every individual AT-SPI D-Bus call — long enough for a
  /// healthy desktop session, short enough that a hung/missing accessible
  /// app falls through to `SnippetExpander`'s clipboard tier promptly
  /// instead of stalling the hotkey.
  public static let callTimeout: Duration = .milliseconds(250)
}
