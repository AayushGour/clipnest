import Foundation

/// Which chord a paste keystroke needs, decided from the target app's
/// identifier: `Ctrl+V` almost everywhere, but `Ctrl+Shift+V` in terminal
/// emulators, where plain `Ctrl+V` means something else entirely (often
/// nothing at all, or a control character) — this has no macOS analogue
/// (⌘V is paste everywhere, including Terminal.app).
public enum TerminalAppRegistry {
  /// App identifiers (bundle/desktop-file/WM_CLASS style — whatever
  /// `FrontmostAppRef.bundleID` is populated with by the Linux
  /// `FrontmostAppReferenceProviding` implementation, out of this module's
  /// scope) known to require `Ctrl+Shift+V` for paste. Kept in exactly ONE
  /// place per coding-standards.md's "no magic strings" rule — nothing
  /// else in this module hardcodes a terminal's name.
  public static let terminalIdentifiers: Set<String> = [
    "org.gnome.Terminal",
    "org.gnome.Ptyxis",
    "org.gnome.Console",
    "Alacritty",
    "kitty",
    "xterm",
    "wezterm",
    "foot",
    "Tilix",
    "konsole",
  ]

  /// The modifiers to hold for `V`, given the target app's identifier.
  /// Defaults to plain Ctrl+V (`.control`) whenever `identifier` is `nil`
  /// or unrecognized — this stack never assumes a target is a terminal
  /// without a positive match, since guessing wrong would break paste in
  /// every ordinary app.
  public static func modifiers(forAppIdentifier identifier: String?) -> ModifierMask {
    guard let identifier, terminalIdentifiers.contains(identifier) else { return .control }
    return [.control, .shift]
  }
}
