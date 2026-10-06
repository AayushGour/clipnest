import Foundation

/// The well-known bus name this app owns exactly once per session (see
/// `SingleInstanceDecision`), the object path its control interface lives
/// at, and every interface/member/property name that interface exposes —
/// the spec this task hands down verbatim. Kept in ONE place per
/// `coding-standards.md`'s "no magic strings" rule; nothing else in this
/// module spells any of these inline.
enum ClipnestControlName {
  static let busName = "app.clipnest.Clipnest"
  /// `WM_CLASS`'s `res_name` for every Clipnest toplevel, set via
  /// `g_set_prgname` before `gtk_init()`. MUST stay equal to
  /// `StartupWMClass` in `packaging/linux/desktop/applications/
  /// app.clipnest.Clipnest.desktop` — a `.desktop` entry only associates
  /// with a running window when the two match exactly.
  static let programName = "clipnest"
  /// Human-readable application name (`g_set_application_name`), matching
  /// the `.desktop` entry's `Name=`.
  static let displayName = "Clipnest"
  static let objectPath = "/app/clipnest/Clipnest"
  static let controlInterface = "app.clipnest.Control"
}

enum ClipnestControlMember {
  static let togglePicker = "TogglePicker"
  static let showPicker = "ShowPicker"
  static let hidePicker = "HidePicker"
  static let expandSnippet = "ExpandSnippet"
  static let openSettings = "OpenSettings"
  static let ping = "Ping"
}

enum ClipnestControlProperty {
  static let capabilities = "Capabilities"
}

/// `ShowPicker(a{sv})`'s well-known option keys — populated by whichever
/// caller has the freshest pointer/focus info at the instant of the
/// keypress (typically the Shell extension, via `ShortcutActivated`; see
/// `ClipnestControlService`'s doc comment for why this is one message
/// instead of a round trip).
enum ShowPickerOptionKey {
  static let pointerX = "pointer-x"
  static let pointerY = "pointer-y"
  static let monitor = "monitor"
  static let focus = "focus"
}

/// This app's own `app.clipnest.Control.Capabilities` values — what a
/// caller (the Shell extension, a future CLI) can rely on THIS process
/// supporting, independent of whether the compositor-side
/// `app.clipnest.ShellHelper` extension is installed (see
/// `ShellHelperCapability` for the reverse direction: capabilities the
/// EXTENSION advertises to THIS app).
enum ClipnestControlCapability {
  static let picker = "picker"
  static let snippetExpansion = "snippet-expansion"
  static let settings = "settings"
}

/// The subset of `org.freedesktop.Application` (the Application Activation
/// D-Bus spec) this app implements, so `DBusActivatable=true` in its
/// `.desktop` file works: a compositor/shell that wants to launch or
/// message an already-running Clipnest can do so over D-Bus instead of
/// spawning a new process argv.
enum FreedesktopApplicationName {
  static let interface = "org.freedesktop.Application"
}

enum FreedesktopApplicationMember {
  static let activate = "Activate"
  static let open = "Open"
  static let activateAction = "ActivateAction"
}

/// The standard `org.freedesktop.DBus.Properties` interface, used to serve
/// `Capabilities` as a real D-Bus property (`Get`/`GetAll`) rather than a
/// bespoke method — the contract calls it a "property," and every D-Bus
/// introspection tool expects it exposed this way.
enum FreedesktopPropertiesName {
  static let interface = "org.freedesktop.DBus.Properties"
}

enum FreedesktopPropertiesMember {
  static let get = "Get"
  static let getAll = "GetAll"
}
