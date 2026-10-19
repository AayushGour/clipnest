// WelcomeHotkeyTests.swift

import Testing

@testable import ClipnestViewModels

@Suite("WelcomeHotkey")
struct WelcomeHotkeyTests {
  @Test("macOS default renders glyphs in standard modifier order with spoken words")
  func macDefault() {
    let hotkey = WelcomeHotkey.macOS(
      command: true, option: true, control: false, shift: false, key: "V")
    #expect(hotkey.displayText == "⌥⌘V")
    #expect(hotkey.spokenText == "Option Command V")
    #expect(hotkey.keyCaps.map(\.label) == ["⌥", "⌘", "V"])
  }

  @Test("macOS orders control, option, shift, command")
  func macOrder() {
    let hotkey = WelcomeHotkey.macOS(
      command: true, option: true, control: true, shift: true, key: "K")
    #expect(hotkey.displayText == "⌃⌥⇧⌘K")
    #expect(hotkey.spokenText == "Control Option Shift Command K")
  }

  @Test("macOS special key glyph gets a spoken name")
  func macSpecialKey() {
    let hotkey = WelcomeHotkey.macOS(
      command: true, option: false, control: false, shift: false, key: "␣")
    #expect(hotkey.spokenText == "Command Space")
  }

  @Test("macOS with an empty key is unbound")
  func macEmptyKey() {
    #expect(
      WelcomeHotkey.macOS(command: true, option: false, control: false, shift: false, key: "")
        == .unbound)
  }

  @Test("GNOME accelerator keeps given order and names Super")
  func gnomeDefault() {
    let hotkey = WelcomeHotkey.gnomeAccelerator("<Alt><Super>v")
    #expect(hotkey.displayText == "Alt + Super + V")
    #expect(hotkey.spokenText == "Alt Super V")
  }

  @Test("GNOME Primary and Control both read as Ctrl; Shift supported")
  func gnomeCtrl() {
    #expect(WelcomeHotkey.gnomeAccelerator("<Primary><Shift>F5").displayText == "Ctrl + Shift + F5")
    #expect(WelcomeHotkey.gnomeAccelerator("<Control>space").displayText == "Ctrl + Space")
  }

  @Test("GNOME empty, disabled or key-less accelerators are unbound")
  func gnomeUnbound() {
    #expect(WelcomeHotkey.gnomeAccelerator("") == .unbound)
    #expect(WelcomeHotkey.gnomeAccelerator("  ") == .unbound)
    #expect(WelcomeHotkey.gnomeAccelerator("disabled") == .unbound)
    #expect(WelcomeHotkey.gnomeAccelerator("<Alt><Super>") == .unbound)
  }

  @Test("unbound has no display or spoken text")
  func unbound() {
    #expect(WelcomeHotkey.unbound.displayText == nil)
    #expect(WelcomeHotkey.unbound.spokenText == nil)
    #expect(WelcomeHotkey.unbound.isBound == false)
  }
}
