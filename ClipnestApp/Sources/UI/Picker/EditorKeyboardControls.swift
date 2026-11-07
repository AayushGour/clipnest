// EditorKeyboardControls.swift
//
// T-EDIT14 / T-EDIT15: the AppKit controls that make the edit popups (item
// editor and snippet editor) keyboard-reachable.
//
// WHY AppKit buttons instead of SwiftUI `Button`: with System Settings ->
// Keyboard -> "Keyboard navigation" OFF (the default), Tab skips every
// SwiftUI/AppKit push button -- only text fields and lists take focus. A
// `.focusable()` on a SwiftUI Button follows the same system setting. The
// reliable fix is an `NSButton` subclass that answers `acceptsFirstResponder`
// / `canBecomeKeyView` itself, which puts it in the window's key-view loop
// regardless of that setting. The loop order is then AppKit's own geometric
// order (`autorecalculatesKeyViewLoop` on `ItemEditorWindow` and
// `SnippetEditorWindow`): top-to-bottom,
// left-to-right = Bold, Italic, Underline, editor, Cancel, Save, wrapping.
// AppKit draws the focus ring on whichever button is first responder.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI

/// Key codes (`NSEvent.keyCode`) this file reacts to.
enum EditorKeyCode {
  static let returnKey: UInt16 = 36
  static let keypadEnter: UInt16 = 76
  static let tab: UInt16 = 48

  static func isReturn(_ code: UInt16) -> Bool { code == returnKey || code == keypadEnter }
}

/// `keyEquivalent` strings for the popup's default / cancel buttons.
enum EditorKeyEquivalent {
  static let returnKey = "\r"
  static let escape = "\u{1b}"
}

/// A push button that always takes part in the Tab loop while enabled.
/// Space activates it (stock `NSButton` behaviour once it is first responder).
@MainActor
final class KeyboardFocusableButton: NSButton {
  var onPress: () -> Void = {}
  /// ⌘Return presses this button even though its own key equivalent is plain
  /// Return (Save).
  var activatesOnCommandReturn = false
  /// Take first responder when added to a window (Go Back, on the lossy row).
  var takesInitialFocus = false

  /// The enabled state the form asked for (`setEnabled(_:)`). SwiftUI writes
  /// the environment's `isEnabled` (true) onto an `NSControl` representable
  /// after `makeNSView` (proved by probe, T-EDIT18), clobbering a `false` set
  /// at creation; the form's Save then showed enabled and Tab-reachable until
  /// its first edit. Writes through `isEnabled` are therefore ignored.
  private var requestedEnabled = true

  override var isEnabled: Bool {
    get { requestedEnabled }
    set { super.isEnabled = requestedEnabled }
  }

  /// The only way to change the enabled state.
  func setEnabled(_ enabled: Bool) {
    requestedEnabled = enabled
    super.isEnabled = enabled
  }

  override var acceptsFirstResponder: Bool { isEnabled }
  override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    target = self
    action = #selector(pressed)
  }

  @available(*, unavailable, message: "KeyboardFocusableButton does not support NSCoding")
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for KeyboardFocusableButton")
  }

  @objc private func pressed() { onPress() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard takesInitialFocus, let window else { return }
    // Deferred a tick, like `SnippetFormView`'s initial focus: a request made
    // before the window is key doesn't take.
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, self.window === window else { return }
      window.makeFirstResponder(self)
    }
  }

  /// Return / Enter press the button when it is first responder, even with no
  /// `keyEquivalent` (the lossy row has no default button). Space is stock.
  override func keyDown(with event: NSEvent) {
    if isEnabled, EditorKeyCode.isReturn(event.keyCode) {
      performClick(nil)
    } else {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
    if EditorKeyCode.isReturn(event.keyCode) {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if modifiers.contains(.command) {
        guard activatesOnCommandReturn else { return false }
        performClick(nil)
        return true
      }
      // Plain Return inserts a newline in the editor; it saves only when
      // focus is elsewhere.
      if window?.firstResponder is NSTextView { return false }
    } else if keyEquivalent == EditorKeyEquivalent.escape,
      let text = window?.firstResponder as? NSTextView, text.hasMarkedText()
    {
      // Esc during IME composition belongs to the input method.
      return false
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// SwiftUI wrapper for `KeyboardFocusableButton`.
///
/// A `View` that applies `.disabled(!isEnabled)` around the AppKit control, not
/// a bare `NSViewRepresentable` (T-EDIT18), so the SwiftUI environment agrees
/// with the button (see `KeyboardFocusableButton.requestedEnabled`, which makes
/// the button itself immune to SwiftUI's late `isEnabled` write).
struct EditorButton: View {
  /// Stable accessibility identifier (`ItemEditControl` / `SnippetEditControl` raw value).
  let identifier: String
  let accessibilityLabel: String
  var title: String?
  var symbol: String?
  var help: String?
  var accessibilityHelp: String?
  /// A toggle button reports `isOn` as its pressed state.
  var isToggle = false
  var isOn = false
  var isEnabled = true
  var keyEquivalent = ""
  var activatesOnCommandReturn = false
  var takesInitialFocus = false
  let action: () -> Void

  var body: some View {
    EditorButtonControl(spec: self).disabled(!isEnabled)
  }
}

/// The AppKit side of `EditorButton`.
private struct EditorButtonControl: NSViewRepresentable {
  let spec: EditorButton

  func makeNSView(context: Context) -> KeyboardFocusableButton {
    let button = KeyboardFocusableButton(frame: .zero)
    button.setAccessibilityIdentifier(spec.identifier)
    button.takesInitialFocus = spec.takesInitialFocus
    if let symbol = spec.symbol {
      button.image = NSImage(
        systemSymbolName: symbol, accessibilityDescription: spec.accessibilityLabel)
      button.bezelStyle = .texturedRounded
    } else {
      button.title = spec.title ?? spec.accessibilityLabel
      button.bezelStyle = .rounded
    }
    button.setButtonType(spec.isToggle ? .pushOnPushOff : .momentaryPushIn)
    button.setContentHuggingPriority(.required, for: .horizontal)
    // Apply the full state now: relying on SwiftUI to follow `makeNSView` with
    // `updateNSView` left a fresh form's Save enabled (and in the Tab loop)
    // until the first edit (T-EDIT15 live FAIL e).
    apply(to: button)
    return button
  }

  func updateNSView(_ button: KeyboardFocusableButton, context: Context) {
    apply(to: button)
  }

  /// Every prop that can change after creation, applied on first render and on
  /// each update.
  private func apply(to button: KeyboardFocusableButton) {
    button.onPress = spec.action
    button.setEnabled(spec.isEnabled)
    button.keyEquivalent = spec.keyEquivalent
    button.activatesOnCommandReturn = spec.activatesOnCommandReturn
    button.toolTip = spec.help
    button.setAccessibilityLabel(spec.accessibilityLabel)
    button.setAccessibilityHelp(spec.accessibilityHelp)
    if spec.isToggle { button.state = spec.isOn ? .on : .off }
  }
}

/// The editor's text view: Tab moves focus, ⌥Tab types a tab, ⌘B/I/U format,
/// Esc cancels, and it grabs focus when the popup opens.
@MainActor
final class EditorTextView: NSTextView {
  /// ⌘B / ⌘I / ⌘U (rich-text mode only).
  var onToggleTrait: ((MacEditableRichText.FormatTrait) -> Void)?
  /// Esc while typing.
  var onCancel: (() -> Void)?
  /// Grab first responder when added to a window. Off for the snippet editor,
  /// whose Tag field is the first stop.
  var takesInitialFocus = true

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard takesInitialFocus, let window else { return }
    // Initial focus, deferred a tick (see `KeyboardFocusableButton`).
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, self.window === window else { return }
      window.makeFirstResponder(self)
    }
  }

  /// Tab moves focus on instead of inserting a tab character.
  override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
  override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == EditorKeyCode.tab, modifiers == .option {
      // ⌥Tab = literal tab (the `insertTabIgnoringFieldEditor:` convention).
      insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0))
      return
    }
    super.keyDown(with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    if !hasMarkedText(), let onCancel {
      onCancel()
    } else {
      super.cancelOperation(sender)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let character = event.charactersIgnoringModifiers
    if isRichText, modifiers == .command, let trait = Self.trait(forCharacter: character) {
      onToggleTrait?(trait)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// Layout-aware (Dvorak etc.): matches the typed character, not the key code.
  static func trait(forCharacter character: String?) -> MacEditableRichText.FormatTrait? {
    switch character?.lowercased() {
    case "b": return .bold
    case "i": return .italic
    case "u": return .underline
    default: return nil
    }
  }
}

/// VoiceOver announcement for messages that appear without moving focus.
@MainActor
enum EditorAnnouncer {
  static func announce(_ message: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
}
