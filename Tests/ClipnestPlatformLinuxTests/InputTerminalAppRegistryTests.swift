import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("TerminalAppRegistry")
struct TerminalAppRegistryTests {
  @Test("known terminals require Ctrl+Shift")
  func knownTerminalsRequireShift() {
    for identifier in TerminalAppRegistry.terminalIdentifiers {
      let modifiers = TerminalAppRegistry.modifiers(forAppIdentifier: identifier)
      #expect(modifiers == [.control, .shift], "expected Ctrl+Shift for \(identifier)")
    }
  }

  @Test("an ordinary app defaults to plain Ctrl")
  func ordinaryAppDefaultsToPlainCtrl() {
    #expect(TerminalAppRegistry.modifiers(forAppIdentifier: "org.gnome.TextEditor") == .control)
  }

  @Test("an unknown target (nil identifier) never assumed to be a terminal")
  func nilIdentifierDefaultsToPlainCtrl() {
    #expect(TerminalAppRegistry.modifiers(forAppIdentifier: nil) == .control)
  }

  @Test("the registry contains every terminal named in the task spec")
  func containsSpecifiedTerminals() {
    let expected: Set<String> = [
      "org.gnome.Terminal", "org.gnome.Ptyxis", "org.gnome.Console", "Alacritty", "kitty",
      "xterm", "wezterm", "foot", "Tilix", "konsole",
    ]
    #expect(TerminalAppRegistry.terminalIdentifiers == expected)
  }
}
