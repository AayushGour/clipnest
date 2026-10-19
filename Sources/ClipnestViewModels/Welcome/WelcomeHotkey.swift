// WelcomeHotkey.swift
//
// T-WELCOME1: the live hotkey as the welcome window shows it — individual key
// caps (visual label + spoken form for VoiceOver/Orca) so the UI can render
// caps while assistive tech reads words. Pure; each platform maps its own
// binding in (macOS: KeyboardShortcuts shortcut; Linux: gsettings accelerator).

import Foundation

public struct WelcomeKeyCap: Equatable, Sendable {
  /// What is drawn on the cap (glyph or short name).
  public let label: String
  /// What assistive tech reads.
  public let spoken: String

  public init(label: String, spoken: String) {
    self.label = label
    self.spoken = spoken
  }
}

public enum WelcomeHotkey: Equatable, Sendable {
  case unbound
  /// `separator` joins labels in running text: "" on macOS ("⌥⌘V"), " + " on
  /// Linux ("Alt + Super + V").
  case bound(keys: [WelcomeKeyCap], separator: String)

  public var isBound: Bool {
    if case .bound = self { return true }
    return false
  }

  public var keyCaps: [WelcomeKeyCap] {
    if case .bound(let keys, _) = self { return keys }
    return []
  }

  /// For running text; nil when unbound.
  public var displayText: String? {
    guard case .bound(let keys, let separator) = self else { return nil }
    return keys.map(\.label).joined(separator: separator)
  }

  /// For accessibility labels; nil when unbound.
  public var spokenText: String? {
    guard case .bound(let keys, _) = self else { return nil }
    return keys.map(\.spoken).joined(separator: " ")
  }

  // MARK: macOS

  private static let macSpokenForSpecialKey: [String: String] = [
    "␣": "Space", "↩": "Return", "⇥": "Tab", "⌫": "Delete", "⎋": "Escape",
    "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow",
  ]

  /// Standard macOS modifier order: ⌃ ⌥ ⇧ ⌘, then the key.
  public static func macOS(
    command: Bool, option: Bool, control: Bool, shift: Bool, key: String
  ) -> WelcomeHotkey {
    guard !key.isEmpty else { return .unbound }
    var caps: [WelcomeKeyCap] = []
    if control { caps.append(WelcomeKeyCap(label: "⌃", spoken: "Control")) }
    if option { caps.append(WelcomeKeyCap(label: "⌥", spoken: "Option")) }
    if shift { caps.append(WelcomeKeyCap(label: "⇧", spoken: "Shift")) }
    if command { caps.append(WelcomeKeyCap(label: "⌘", spoken: "Command")) }
    caps.append(WelcomeKeyCap(label: key, spoken: macSpokenForSpecialKey[key] ?? key))
    return .bound(keys: caps, separator: "")
  }

  // MARK: Linux / GNOME

  private static let gnomeModifierNames: [String: String] = [
    "alt": "Alt", "super": "Super", "shift": "Shift", "control": "Ctrl", "ctrl": "Ctrl",
    "primary": "Ctrl", "meta": "Meta", "hyper": "Hyper",
  ]

  /// Parses one GTK/GNOME accelerator string (`<Alt><Super>v`). Modifier
  /// order is preserved as written. Empty, "disabled" or key-less strings are
  /// `.unbound`. Callers unwrap gsettings list syntax themselves.
  public static func gnomeAccelerator(_ accelerator: String) -> WelcomeHotkey {
    var rest = Substring(accelerator.trimmingCharacters(in: .whitespaces))
    var caps: [WelcomeKeyCap] = []
    while rest.first == "<", let close = rest.firstIndex(of: ">") {
      let name = rest[rest.index(after: rest.startIndex)..<close].lowercased()
      guard let display = gnomeModifierNames[name] else { return .unbound }
      caps.append(WelcomeKeyCap(label: display, spoken: display))
      rest = rest[rest.index(after: close)...]
    }
    let key = String(rest)
    guard !key.isEmpty, key.lowercased() != "disabled" else { return .unbound }
    let shown = key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst()
    caps.append(WelcomeKeyCap(label: shown, spoken: shown))
    return .bound(keys: caps, separator: " + ")
  }
}
