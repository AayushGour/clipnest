// SnippetEditorKeyboardTests.swift
//
// T-EDIT15: keyboard behaviour of the snippet editor popup that can be checked
// without a user at the keyboard. Tab / ⌥Tab inside the Body are the item
// editor's `EditorTextView` (covered in `ItemEditorKeyboardTests`); here: the
// live key-view loop of a real `SnippetFormView` against
// `SnippetEditFocusOrder`, the Body in plain-text mode, and the Return / ⌘Return
// / Esc routing of the form's buttons. Focus RINGS, VoiceOver output, Return in
// the Tag field and real key events through the window server need a live check.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI
import Testing

@testable import Clipnest

@Suite("SnippetEditor keyboard")
@MainActor
struct SnippetEditorKeyboardTests {
  private func form(
    _ mode: SnippetFormMode, onSave: @escaping (String, String, String?) -> Void = { _, _, _ in }
  ) -> SnippetFormView {
    SnippetFormView(
      mode: mode, tagError: { _ in nil }, expandShortcut: "⌥⌘E", onSave: onSave, onCancel: {})
  }

  private func liveLoop(_ mode: SnippetFormMode) -> [String] {
    EditorKeyboardTestSupport.liveLoop(
      form(mode),
      size: NSSize(width: 380, height: 460),
      textFieldIdentifiers: [SnippetEditStrings.tagLabel: SnippetEditControl.tag.rawValue])
  }

  private func snippet(title: String, body: String) -> Snippet {
    Snippet(title: title, body: body)
  }

  @Test func filledFormTabOrderMatchesSharedFocusOrder() {
    let live = liveLoop(.edit(snippet(title: "sig", body: "Best")))
    let expected = SnippetEditFocusOrder.controls(canSave: true).map(\.rawValue)
    #expect(Set(live) == Set(expected))
    #expect(EditorKeyboardTestSupport.rotated(live, toStartAt: expected[0]) == expected)
  }

  @Test func emptyFormSkipsDisabledSave() {
    let live = liveLoop(.create)
    let expected = SnippetEditFocusOrder.controls(canSave: false).map(\.rawValue)
    #expect(!live.contains(SnippetEditControl.save.rawValue))
    #expect(Set(live) == Set(expected))
    #expect(EditorKeyboardTestSupport.rotated(live, toStartAt: expected[0]) == expected)
  }

  /// T-EDIT15 live FAIL (e): `EditorButton.makeNSView` used to leave Save at its
  /// default (enabled) until the first update, so a fresh empty form showed an
  /// enabled Save that Space could activate.
  @Test func freshCreateFormSaveIsDisabledOnFirstRenderAndSaveIsANoOp() {
    var saved = 0
    let host = NSHostingView(rootView: form(.create, onSave: { _, _, _ in saved += 1 }))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 460)),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let save = Self.button(withIdentifier: SnippetEditControl.save.rawValue, in: host)
    #expect(save != nil)
    #expect(save?.isEnabled == false)
    #expect(!liveLoop(.create).contains(SnippetEditControl.save.rawValue))
    // Defense in depth: even if something presses it, `save()` is a no-op.
    save?.onPress()
    #expect(saved == 0)
  }

  /// T-EDIT18: the previous test passes on broken code because it reads the
  /// button before SwiftUI's post-make pass. Host the form in an ordered-front
  /// window like `SnippetEditorWindow` and let the run loop turn.
  @Test func freshCreateFormSaveStaysDisabledAfterSwiftUIPostMakePass() {
    let host = NSHostingView(rootView: form(.create))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 460)),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // as SnippetEditorWindow; avoids a double release
    window.autorecalculatesKeyViewLoop = true
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    for _ in 0..<10 {
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let save = Self.button(withIdentifier: SnippetEditControl.save.rawValue, in: host)
    #expect(save != nil)
    #expect(save?.isEnabled == false)
    #expect(save?.canBecomeKeyView == false)
  }

  @Test func realSnippetEditorWindowFreshFormSaveDisabled() {
    let window = SnippetEditorWindow()
    window.show(
      mode: .create, pickerPanel: nil, tagError: { _ in nil }, expandShortcut: "⌥⌘E",
      onSave: { _, _, _ in }, onClose: {})
    defer { window.close() }
    for _ in 0..<20 {
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let save = window.contentView.flatMap {
      Self.button(withIdentifier: SnippetEditControl.save.rawValue, in: $0)
    }
    #expect(save != nil)
    #expect(save?.isEnabled == false)
    #expect(save?.canBecomeKeyView == false)
  }

  /// T-EDIT18 root cause, reproduced deterministically: SwiftUI writes the
  /// environment's `isEnabled` (true) onto an `NSControl` after `makeNSView`
  /// (probe: a representable that sets false in make only ends up true), and
  /// in the live app no `updateNSView` followed, leaving Save enabled. A late
  /// external write must not override what the form asked for.
  @Test func lateExternalIsEnabledWriteCannotReEnableADisabledButton() {
    let button = KeyboardFocusableButton(frame: .zero)
    button.setEnabled(false)
    button.isEnabled = true  // what SwiftUI does after makeNSView
    #expect(button.isEnabled == false)
    #expect(button.acceptsFirstResponder == false)
    #expect(button.canBecomeKeyView == false)
    // Drawing and AX read the cell / accessibility state: they must agree.
    #expect((button.cell as? NSButtonCell)?.isEnabled == false)
    #expect(button.isAccessibilityEnabled() == false)
    button.setEnabled(true)
    #expect((button.cell as? NSButtonCell)?.isEnabled == true)
    #expect(button.isAccessibilityEnabled())
    button.setEnabled(false)
    button.setEnabled(true)
    #expect(button.isEnabled)
    #expect(button.canBecomeKeyView)
  }

  private static func button(withIdentifier id: String, in view: NSView)
    -> KeyboardFocusableButton?
  {
    if let button = view as? KeyboardFocusableButton, button.accessibilityIdentifier() == id {
      return button
    }
    for sub in view.subviews { if let found = button(withIdentifier: id, in: sub) { return found } }
    return nil
  }

  @Test func saveAsSnippetPrefillEnablesSaveOnlyOnceATagExists() {
    // Body prefilled but no Tag yet: Save stays disabled.
    #expect(!liveLoop(.createFromClip("body")).contains(SnippetEditControl.save.rawValue))
  }

  @Test func bodyIsAPlainTextEditorThatDoesNotTakeInitialFocus() {
    let controller = RichTextEditorController(initialText: "x")
    let view = RichTextEditorView(
      controller: controller, initial: NSAttributedString(string: "x"), isRichText: false,
      onCancel: {}, identifier: SnippetEditControl.body.rawValue,
      accessibilityLabel: SnippetEditStrings.bodyLabel, takesInitialFocus: false)
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    let text = Self.firstTextView(in: host)
    #expect(text?.isRichText == false)
    #expect(text?.accessibilityIdentifier() == SnippetEditControl.body.rawValue)
    #expect(text?.accessibilityLabel() == SnippetEditStrings.bodyLabel)
    #expect((text as? EditorTextView)?.takesInitialFocus == false)
  }

  private static func firstTextView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
    return nil
  }

  // MARK: Key routing of the form's buttons (same controls as the item editor)

  private func saveButton(in window: NSWindow) -> (KeyboardFocusableButton, () -> Int) {
    let button = KeyboardFocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    button.keyEquivalent = EditorKeyEquivalent.returnKey
    button.activatesOnCommandReturn = true
    var count = 0
    button.onPress = { count += 1 }
    window.contentView?.addSubview(button)
    return (button, { count })
  }

  private func window() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
  }

  @Test func returnInBodyIsANewlineNotSave() {
    let window = window()
    let (button, pressCount) = saveButton(in: window)
    let body = EditorTextView(frame: NSRect(x: 0, y: 50, width: 200, height: 100))
    window.contentView?.addSubview(body)
    window.makeFirstResponder(body)
    let event = EditorKeyboardTestSupport.keyEvent(EditorKeyCode.returnKey, chars: "\r", [])
    #expect(!button.performKeyEquivalent(with: event))
    #expect(pressCount() == 0)
  }

  @Test func returnOutsideBodyAndCommandReturnAnywhereSave() {
    let window = window()
    let (button, pressCount) = saveButton(in: window)
    let body = EditorTextView(frame: NSRect(x: 0, y: 50, width: 200, height: 100))
    window.contentView?.addSubview(body)
    window.makeFirstResponder(button)
    let plain = EditorKeyboardTestSupport.keyEvent(EditorKeyCode.returnKey, chars: "\r", [])
    #expect(button.performKeyEquivalent(with: plain))
    window.makeFirstResponder(body)
    let command = EditorKeyboardTestSupport.keyEvent(
      EditorKeyCode.returnKey, chars: "\r", .command)
    #expect(button.performKeyEquivalent(with: command))
    #expect(pressCount() == 2)
  }

  @Test func escapeCancelsFromTheBodyUnlessComposingText() {
    let window = window()
    let cancel = KeyboardFocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    cancel.keyEquivalent = EditorKeyEquivalent.escape
    var cancelled = 0
    cancel.onPress = { cancelled += 1 }
    window.contentView?.addSubview(cancel)
    let body = EditorTextView(frame: NSRect(x: 0, y: 50, width: 200, height: 100))
    window.contentView?.addSubview(body)
    window.makeFirstResponder(body)
    let esc = EditorKeyboardTestSupport.keyEvent(53, chars: EditorKeyEquivalent.escape, [])
    #expect(cancel.performKeyEquivalent(with: esc))
    #expect(cancelled == 1)
    // IME composition owns Esc.
    body.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!cancel.performKeyEquivalent(with: esc))
    #expect(cancelled == 1)
  }
}
