// ItemEditorKeyboardTests.swift
//
// T-EDIT14: keyboard behaviour of the edit popup that can be checked without
// a user at the keyboard: Tab / Shift+Tab / ⌥Tab in the text view, the ⌘B/I/U
// character mapping, and the live key-view loop of a real `ItemEditorView`
// (built in an off-screen window) against `ItemEditFocusOrder`. Focus RINGS,
// VoiceOver output and real key events through the window server still need a
// live check.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI
import Testing

@testable import Clipnest

/// Records focus-move requests instead of needing a populated key loop.
@MainActor
private final class RecordingWindow: NSWindow {
  var nextCount = 0
  var previousCount = 0
  override func selectNextKeyView(_ sender: Any?) { nextCount += 1 }
  override func selectPreviousKeyView(_ sender: Any?) { previousCount += 1 }
}

@Suite("ItemEditor keyboard")
@MainActor
struct ItemEditorKeyboardTests {
  private func makeWindow() -> RecordingWindow {
    RecordingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
  }

  private func keyEvent(_ code: UInt16, chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    EditorKeyboardTestSupport.keyEvent(code, chars: chars, flags)
  }

  @Test func tabMovesFocusAndInsertsNothing() {
    let window = makeWindow()
    let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    window.contentView?.addSubview(view)
    view.insertTab(nil)
    view.insertBacktab(nil)
    #expect(window.nextCount == 1)
    #expect(window.previousCount == 1)
    #expect(view.string.isEmpty)
  }

  @Test func optionTabInsertsALiteralTab() {
    let window = makeWindow()
    let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    window.contentView?.addSubview(view)
    view.keyDown(with: keyEvent(EditorKeyCode.tab, chars: "\t", .option))
    #expect(view.string == "\t")
    #expect(window.nextCount == 0)
  }

  @Test func escapeForwardsToCancel() {
    let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    var cancelled = false
    view.onCancel = { cancelled = true }
    view.cancelOperation(nil)
    #expect(cancelled)
  }

  @Test func commandBIUMapToTraitsLayoutIndependently() {
    #expect(EditorTextView.trait(forCharacter: "b") == .bold)
    #expect(EditorTextView.trait(forCharacter: "I") == .italic)
    #expect(EditorTextView.trait(forCharacter: "u") == .underline)
    #expect(EditorTextView.trait(forCharacter: "x") == nil)
    #expect(EditorTextView.trait(forCharacter: nil) == nil)
  }

  @Test func commandBTogglesBoldOnlyInRichMode() {
    let view = EditorTextView(frame: .zero)
    var toggled: [MacEditableRichText.FormatTrait] = []
    view.onToggleTrait = { toggled.append($0) }
    let event = keyEvent(11, chars: "b", .command)
    view.isRichText = true
    #expect(view.performKeyEquivalent(with: event))
    view.isRichText = false
    _ = view.performKeyEquivalent(with: event)
    #expect(toggled == [.bold])
  }

  @Test func returnPressesOnlyTheFocusedLossyButton() {
    let window = makeWindow()
    let goBack = KeyboardFocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    let saveAnyway = KeyboardFocusableButton(frame: NSRect(x: 90, y: 0, width: 80, height: 24))
    var pressed: [String] = []
    goBack.onPress = { pressed.append("goBack") }
    saveAnyway.onPress = { pressed.append("saveAnyway") }
    window.contentView?.addSubview(goBack)
    window.contentView?.addSubview(saveAnyway)
    window.makeFirstResponder(goBack)
    let returnEvent = keyEvent(EditorKeyCode.returnKey, chars: "\r", [])
    // No default button: the key equivalent path does nothing for either.
    #expect(!window.performKeyEquivalent(with: returnEvent))
    goBack.keyDown(with: returnEvent)
    #expect(pressed == ["goBack"])
  }

  // MARK: Live key-view loop

  /// Tab order of the real SwiftUI popup, read from AppKit's key-view loop.
  private func liveLoop(mode: ItemEditMode, text: String) -> [String] {
    let attributed = NSAttributedString(
      string: text, attributes: MacEditableRichText.defaultAttributes)
    return EditorKeyboardTestSupport.liveLoop(
      ItemEditorView(
        mode: mode, isLossy: false, initial: attributed,
        save: { _ in .itemNoLongerExists }, onSaved: {}, onCancel: {}))
  }

  @Test func contentPopupTabOrderMatchesSharedFocusOrder() {
    let clip = ClipItem(kind: .text, previewText: "x", contentHash: "h")
    let expected = ItemEditFocusOrder.controls(for: .content(clip), canSave: true).map(\.rawValue)
    let live = liveLoop(mode: .content(clip), text: "hello")
    // The loop is a ring: compare as rotation-insensitive sequence.
    #expect(Set(live) == Set(expected))
    let start = live.firstIndex(of: expected[0]) ?? 0
    let rotated = Array(live[start...] + live[..<start])
    #expect(rotated == expected)
  }

  @Test func recognizedTextPopupHasNoToolbarStops() {
    let clip = ClipItem(kind: .image, previewText: "x", contentHash: "h", ocrText: "x")
    let expected = ItemEditFocusOrder.controls(for: .recognizedText(clip), canSave: true)
      .map(\.rawValue)
    let live = liveLoop(mode: .recognizedText(clip), text: "hello")
    #expect(Set(live) == Set(expected))
    let start = live.firstIndex(of: expected[0]) ?? 0
    #expect(Array(live[start...] + live[..<start]) == expected)
  }

  @Test func emptyEditorSkipsDisabledSave() {
    let clip = ClipItem(kind: .text, previewText: "x", contentHash: "h")
    let live = liveLoop(mode: .content(clip), text: "")
    #expect(!live.contains(ItemEditControl.save.rawValue))
    #expect(live.contains(ItemEditControl.cancel.rawValue))
  }
}
