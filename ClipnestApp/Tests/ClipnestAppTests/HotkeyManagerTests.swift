// HotkeyManagerTests.swift
//
// Covers `HotkeyManager.shouldToggle(for:matching:)` — the only pure logic in
// the ⌥⌘V pass-through fix. Installing real `NSEvent` monitors, and whether
// Finder actually still receives the chord, are system boundaries verified by
// hand (see the fix report), not faked here.

import AppKit
import KeyboardShortcuts
import Testing

@testable import Clipnest

@MainActor
@Suite("HotkeyManager.shouldToggle")
struct HotkeyManagerTests {

  /// Carbon virtual keycode for "V" (`kVK_ANSI_V`), the key in the default
  /// picker shortcut.
  private static let vKeyCode: UInt16 = 0x09

  /// Carbon virtual keycode for "B" (`kVK_ANSI_B`) — an arbitrary other key.
  private static let bKeyCode: UInt16 = 0x0B

  private static let optionCommandV = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .option])

  private func keyDown(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    isARepeat: Bool = false
  ) -> NSEvent {
    // `characters` is deliberately empty: `Shortcut(event:)` reads only
    // `keyCode`/`modifierFlags`, and `HotkeyManager` never touches typed
    // characters (see its privacy note).
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: isARepeat,
      keyCode: keyCode
    )!
  }

  @Test("exact chord matches")
  func exactChordMatches() {
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.command, .option])
    #expect(HotkeyManager.shouldToggle(for: event, matching: Self.optionCommandV))
  }

  @Test("missing a modifier does not match")
  func missingModifierDoesNotMatch() {
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.command])
    #expect(!HotkeyManager.shouldToggle(for: event, matching: Self.optionCommandV))
  }

  @Test("an extra modifier does not match")
  func extraModifierDoesNotMatch() {
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.command, .option, .control])
    #expect(!HotkeyManager.shouldToggle(for: event, matching: Self.optionCommandV))
  }

  @Test("a different key does not match")
  func differentKeyDoesNotMatch() {
    let event = keyDown(keyCode: Self.bKeyCode, modifiers: [.command, .option])
    #expect(!HotkeyManager.shouldToggle(for: event, matching: Self.optionCommandV))
  }

  /// Holding the chord down must open the picker once, not once per
  /// auto-repeat tick.
  @Test("auto-repeat does not match")
  func autoRepeatDoesNotMatch() {
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.command, .option], isARepeat: true)
    #expect(!HotkeyManager.shouldToggle(for: event, matching: Self.optionCommandV))
  }

  /// A cleared shortcut means the hotkey is off — every event must fall
  /// through untouched rather than matching "nothing."
  @Test("no configured shortcut never matches")
  func noShortcutNeverMatches() {
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.command, .option])
    #expect(!HotkeyManager.shouldToggle(for: event, matching: nil))
  }

  /// Caps Lock is a lock state, not a chord modifier — it must not stop a
  /// match. This is `KeyboardShortcuts.Shortcut(event:)`'s normalization,
  /// asserted here because `shouldToggle` depends on it.
  @Test("Caps Lock is ignored")
  func capsLockIgnored() {
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.command, .option, .capsLock])
    #expect(HotkeyManager.shouldToggle(for: event, matching: Self.optionCommandV))
  }

  /// The picker shortcut is also matched when Clipnest itself has focus (the
  /// local monitor), so a shortcut the user rebinds to something without ⌘
  /// must work the same way.
  @Test("matches a rebound chord")
  func matchesReboundChord() {
    let rebound = KeyboardShortcuts.Shortcut(.v, modifiers: [.control, .shift])
    let event = keyDown(keyCode: Self.vKeyCode, modifiers: [.control, .shift])
    #expect(HotkeyManager.shouldToggle(for: event, matching: rebound))
    let oldChord = keyDown(keyCode: Self.vKeyCode, modifiers: [.command, .option])
    #expect(!HotkeyManager.shouldToggle(for: oldChord, matching: rebound))
  }
}
