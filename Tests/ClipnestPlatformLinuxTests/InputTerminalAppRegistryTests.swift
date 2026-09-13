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

  // MARK: - isTerminal(appIdentifier:) — the direct predicate
  // LinuxClipboardSelectionReplacer's terminal-decline gate (T-TERMPASTE1)
  // now calls, in place of inferring "is terminal" from
  // `modifiers(forAppIdentifier:) == [.control, .shift]`. These tests pin
  // the predicate itself, independent of the chord it happens to agree
  // with today for every current entry.

  @Test("every known terminal identifier is reported as a terminal")
  func knownTerminalsAreReportedAsTerminals() {
    for identifier in TerminalAppRegistry.terminalIdentifiers {
      #expect(
        TerminalAppRegistry.isTerminal(appIdentifier: identifier),
        "expected \(identifier) to be reported as a terminal")
    }
  }

  @Test("an ordinary app is not reported as a terminal")
  func ordinaryAppIsNotReportedAsTerminal() {
    #expect(!TerminalAppRegistry.isTerminal(appIdentifier: "org.gnome.TextEditor"))
  }

  @Test("a nil identifier is never assumed to be a terminal")
  func nilIdentifierIsNotReportedAsTerminal() {
    #expect(!TerminalAppRegistry.isTerminal(appIdentifier: nil))
  }
}
