import Foundation

/// The GNOME Shell extension's D-Bus identity — verbatim from
/// `extension/src/core/service.js`'s `ShellHelperService` constants and
/// `extension/dbus/app.clipnest.ShellHelper1.xml`. This app is a CLIENT of
/// this interface (the extension is the server); `ClipnestControlName` in
/// this same directory is the reverse (this app as server).
enum ShellHelperName {
  static let busName = "app.clipnest.ShellHelper"
  static let objectPath = "/app/clipnest/ShellHelper"
  static let interface = "app.clipnest.ShellHelper1"
}

enum ShellHelperMember {
  static let sendKeyChord = "SendKeyChord"
  static let focusAndSendKeyChord = "FocusAndSendKeyChord"
  static let getFocusedApp = "GetFocusedApp"
  static let getPointer = "GetPointer"
  static let getMonitorWorkArea = "GetMonitorWorkArea"
  static let placeWindow = "PlaceWindow"
  static let unplaceWindow = "UnplaceWindow"
  static let shortcutActivated = "ShortcutActivated"
  /// `Capabilities`'s companion signal — see
  /// `ShellHelperResponses.isCapabilitiesChanged`'s doc comment for how
  /// this app reacts to it (T-P10J: added alongside fixing the missing
  /// `AddMatch` rule that used to make this, `ShortcutActivated`, and
  /// `ClipboardChanged` all unreachable regardless of whether this app
  /// even recognized their member names).
  static let capabilitiesChanged = "CapabilitiesChanged"
  // The five clipboard-payload members (task P8-C) — see
  // `ShellHelperRequests`/`ShellHelperResponses`' doc comments for why
  // these were absent until `DBusValue.unixFD`/`DBusConnection`'s
  // `sendmsg`/`recvmsg`+`SCM_RIGHTS` support existed.
  static let setClipboardWatch = "SetClipboardWatch"
  static let getClipboardMimeTypes = "GetClipboardMimeTypes"
  static let readClipboard = "ReadClipboard"
  static let setClipboard = "SetClipboard"
  static let clipboardChanged = "ClipboardChanged"
}

/// `GetClipboardMimeTypes`/`ReadClipboard`/`ClipboardChanged`'s
/// `selection: u` argument. This is the raw ordinal of Mutter's OWN
/// `MetaSelectionType` C enum (`src/core/meta-selection.h`) — GJS's D-Bus
/// export of the extension's methods passes it through unchanged, and
/// `extension/dist/esm/core/clipboard.js` compares it directly against
/// `Meta.SelectionType.SELECTION_CLIPBOARD`/`SELECTION_PRIMARY`. Verified
/// against Mutter's own header rather than guessed: `NONE=0, PRIMARY=1,
/// SECONDARY=2, CLIPBOARD=3, DND=4`. This app only ever asks for the two
/// X11-selection-shaped cases — `SECONDARY`/`DND` have no corresponding
/// concept this app tracks.
public enum ShellHelperClipboardSelection: UInt32, Equatable, Sendable {
  case primary = 1
  case clipboard = 3
}

/// `GetFocusedApp()`'s `a{sv}` reply keys — verbatim from
/// `extension/src/core/placement.js`'s `getFocusedApp()`, the one place
/// that builds this dict. Constants rather than inline literals per
/// coding-standards.md's no-magic-strings rule; `ShellFocusedApp.parse`
/// is the only reader.
///
/// Every field here is IDENTITY metadata (app id, WM class, pid, mutter's
/// stable window sequence, x11-vs-wayland client type) — the extension
/// never puts window titles or any selection/clipboard text in this dict,
/// which is why `LinuxClipboardSelectionReplacer`'s diagnostics may log it
/// verbatim without violating the never-log-content rule.
enum ShellFocusedAppKey {
  static let appID = "app-id"
  static let name = "name"
  static let wmClass = "wm-class"
  static let pid = "pid"
  static let windowSerial = "window-serial"
  static let clientType = "client-type"
}

/// Decoded `GetFocusedApp()` reply — the compositor's OWN answer to "who
/// has keyboard focus right now", which on Wayland is the ONLY correct
/// answer: `_NET_ACTIVE_WINDOW` reports X11 `None` for a native-Wayland
/// focused window, and AT-SPI reports whichever accessible object last
/// claimed `FOCUSED` state, which can disagree with both.
///
/// Exists to give `GetFocusedApp` its first real reader. Until this type,
/// the extension implemented and tested the method and no Swift code ever
/// called it — the exact "implemented, tested, documented, shipped,
/// unreachable" shape coding-standards.md's false-success section names as
/// a live instance in this repo.
public struct ShellFocusedApp: Equatable, Sendable {
  public var appID: String?
  public var name: String?
  public var wmClass: String?
  public var pid: Int32?
  public var windowSerial: Int32?
  public var clientType: String?

  public init(
    appID: String?, name: String?, wmClass: String?, pid: Int32?, windowSerial: Int32?,
    clientType: String?
  ) {
    self.appID = appID
    self.name = name
    self.wmClass = wmClass
    self.pid = pid
    self.windowSerial = windowSerial
    self.clientType = clientType
  }

  /// Single-line, metadata-only rendering for log lines — no window title,
  /// no clipboard/selection bytes, only the identity fields above. `?` for
  /// an absent field so an unfocused/unknown case can never read as a
  /// focused one (coding-standards.md: a value that cannot say "I do not
  /// know" will be forced to lie).
  ///
  /// N3 fix (T-COPYFLAKE1 review): `name` used to be decoded, stored, and
  /// deliberately left OUT of this rendering with no other production
  /// reader anywhere — implemented, tested, and shipped with nobody ever
  /// looking at it, the exact "no-reader path" coding-standards.md's
  /// smoke test exists to catch. It is safe to log: `ShellFocusedAppKey`'s
  /// own doc comment (and the extension's `placement.js` source,
  /// `Shell.WindowTracker.get_default().focus_app.get_name()`) confirm
  /// this is the human-readable APPLICATION name (e.g. "Firefox"), never a
  /// window title or any clipboard/selection content. Included here so
  /// `LinuxClipboardSelectionReplacer`'s three `.notice` call sites that
  /// already render `logDescription` become its real reader.
  public var logDescription: String {
    "wmClass=\(wmClass ?? "?") appID=\(appID ?? "?") name=\(name ?? "?")"
      + " pid=\(pid.map(String.init) ?? "?") windowSerial=\(windowSerial.map(String.init) ?? "?")"
      + " clientType=\(clientType ?? "?")"
  }
}

enum ShellHelperProperty {
  static let protocolVersion = "ProtocolVersion"
  static let shellVersion = "ShellVersion"
  static let capabilities = "Capabilities"
}

/// The `app.clipnest.Clipnest.Keybindings` GSettings schema both the app
/// and the extension read for the two mutter-level global shortcuts (see
/// `extension/src/core/keybindings.js`) — accelerators live here, NOT on
/// the D-Bus contract, so rebinding in Settings is a single `set_strv()`
/// with no IPC and no way for the two to disagree. `HotkeyBackend`'s
/// `.shellExtensionKeybinding` case writes through this schema; it is a
/// DIFFERENT schema from `GSettingsCustomKeybinding`'s
/// `org.gnome.settings-daemon.plugins.media-keys` floor (tier 4), which
/// exists for desktops with no Clipnest extension enabled at all.
enum ShellExtensionKeybindingSchema {
  static let schemaID = "app.clipnest.Clipnest.Keybindings"
  /// Mirrors `Keybindings.ACTIONS` in `extension/src/core/keybindings.js`
  /// exactly — a mismatch here would silently produce a GSettings key the
  /// extension never binds.
  static let togglePickerKey = "toggle-picker"
  static let expandSnippetKey = "expand-snippet"
}

/// `app.clipnest.ShellHelper1.Capabilities`' well-known values — see the
/// XML contract's own inline comment (`"clipboard" "hotkeys" "paste"
/// "pointer" "placement" "focus"`). Kept as typed cases (not bare strings)
/// so `ShellHelperCapabilities`'s negotiation logic can't typo a feature
/// name it's checking for.
public enum ShellHelperCapability: String, CaseIterable, Equatable, Sendable {
  case clipboard
  case hotkeys
  case paste
  case pointer
  case placement
  case focus
}

/// `PlaceWindow(window_token, x, y, flags)`'s `flags` bitmask — verbatim
/// from the contract XML's own inline comment ("1 above, 2 sticky, 4
/// skip-taskbar").
enum PlaceWindowFlag {
  static let above: UInt32 = 1
  static let sticky: UInt32 = 2
  static let skipTaskbar: UInt32 = 4
}
