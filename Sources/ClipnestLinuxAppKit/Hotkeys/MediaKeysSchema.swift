import Foundation

/// `org.gnome.settings-daemon.plugins.media-keys` — the universal GSettings
/// floor hotkey tier (this task's priority-4, "works on every target
/// release and both session types"): a custom keybinding invoking a CLI,
/// bound the exact same way GNOME Settings' own "Custom Shortcuts" UI
/// binds one, so it works identically whether the user's session is
/// X11 or Wayland and regardless of which GNOME version is running.
enum MediaKeysSchema {
  static let mainSchemaID = "org.gnome.settings-daemon.plugins.media-keys"
  static let customKeybindingsListKey = "custom-keybindings"

  /// The per-binding schema is "relocatable" (no fixed path of its own) —
  /// every instance is addressed by an explicit path under this prefix,
  /// which is why `GSettingsKeybindingPath` exists at all.
  static let customKeybindingSchemaID =
    "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
  static let basePath = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"

  static let nameKey = "name"
  static let commandKey = "command"
  static let bindingKey = "binding"
}
