// RichTextEditorView.swift
//
// `NSViewRepresentable` over `NSScrollView` + `NSTextView` for the item
// editor popup and the snippet editor's plain-text Body.
// `RichTextEditorController` is the SwiftUI-side handle: the toolbar and Save
// talk to it, it talks to the live `NSTextView`.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI

/// Bridges the toolbar / Save button to the live `NSTextView`. Main-actor
/// only (everything it touches is AppKit).
@MainActor
final class RichTextEditorController: ObservableObject {
  /// Current plain text, mirrored on every edit so SwiftUI can gate Save.
  @Published private(set) var plainText: String

  /// Traits "on" for the current selection / typing style (toolbar pressed state).
  @Published private(set) var activeTraits: Set<MacEditableRichText.FormatTrait> = []

  fileprivate weak var textView: NSTextView?

  init(initialText: String) {
    plainText = initialText
  }

  fileprivate func textDidChange() {
    plainText = textView?.string ?? ""
    refreshActiveTraits()
  }

  fileprivate func refreshActiveTraits() {
    guard let textView, let storage = textView.textStorage else { return }
    let traits = MacEditableRichText.activeTraits(
      in: storage, selection: textView.selectedRange(),
      typingAttributes: textView.typingAttributes)
    if traits != activeTraits { activeTraits = traits }
  }

  /// Puts the caret back in the editor (after Go Back on the lossy row).
  func focusEditor() {
    DispatchQueue.main.async { [weak textView] in
      guard let textView else { return }
      textView.window?.makeFirstResponder(textView)
    }
  }

  /// Toggles bold/italic/underline on the selection, or — with an empty
  /// selection — on the typing attributes used for the next typed characters.
  func toggle(_ trait: MacEditableRichText.FormatTrait) {
    defer { refreshActiveTraits() }
    guard let textView, let storage = textView.textStorage else { return }
    let range = textView.selectedRange()
    if range.length > 0 {
      guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
      MacEditableRichText.toggle(trait, in: storage, range: range)
      textView.didChangeText()
    } else {
      // Reuse the same toggle logic on a one-character probe carrying the
      // typing attributes, then take the resulting attributes back.
      let probe = NSMutableAttributedString(
        string: " ", attributes: textView.typingAttributes)
      MacEditableRichText.toggle(trait, in: probe, range: NSRange(location: 0, length: 1))
      textView.typingAttributes = probe.attributes(at: 0, effectiveRange: nil)
    }
  }

  /// Immutable copy of the current text storage (for off-main serialization)
  /// plus the plain text and whether it carries formatting. Main actor: reads
  /// the live text view.
  func snapshot() -> Snapshot? {
    guard let storage = textView?.textStorage else { return nil }
    let copy = NSAttributedString(attributedString: storage)
    return Snapshot(
      attributed: copy, plainText: copy.string,
      hasFormatting: MacEditableRichText.hasFormatting(copy))
  }

  struct Snapshot: @unchecked Sendable {
    // `NSAttributedString` isn't `Sendable`, but this is a private immutable
    // copy never mutated or shared after creation, so handing it to a
    // detached task for RTF serialization is safe.
    let attributed: NSAttributedString
    let plainText: String
    let hasFormatting: Bool
  }
}

struct RichTextEditorView: NSViewRepresentable {
  let controller: RichTextEditorController
  let initial: NSAttributedString
  /// False for recognized-text mode: plain text only, no formatting.
  let isRichText: Bool
  /// Esc while the caret is in the editor.
  let onCancel: () -> Void
  /// Accessibility identifier / label of the text view (the snippet editor
  /// passes its Body's; the item editor passes `ItemEditStrings.textLabel`).
  var identifier = ItemEditControl.editor.rawValue
  var accessibilityLabel: String?
  /// False when another control owns the initial focus (the snippet's Tag).
  var takesInitialFocus = true

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    let textView = EditorTextView(frame: .zero)
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    scrollView.documentView = textView
    textView.onCancel = onCancel
    let controller = controller
    textView.onToggleTrait = { [weak controller] trait in controller?.toggle(trait) }
    textView.setAccessibilityIdentifier(identifier)
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.takesInitialFocus = takesInitialFocus
    textView.isRichText = isRichText
    textView.allowsUndo = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.typingAttributes = MacEditableRichText.defaultAttributes
    if !isRichText {
      textView.font = MacEditableRichText.defaultAttributes[.font] as? NSFont
      textView.textColor = MacEditableRichText.defaultAttributes[.foregroundColor] as? NSColor
    }
    textView.textStorage?.setAttributedString(initial)
    textView.delegate = context.coordinator
    controller.textView = textView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    // Initial focus is `EditorTextView.viewDidMoveToWindow`'s job.
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    (nsView.documentView as? EditorTextView)?.onCancel = onCancel
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    let controller: RichTextEditorController

    init(controller: RichTextEditorController) { self.controller = controller }

    func textDidChange(_ notification: Notification) {
      controller.textDidChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      controller.refreshActiveTraits()
    }
  }
}
