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
