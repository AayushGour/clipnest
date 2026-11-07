// ItemEditorView.swift
//
// SwiftUI body of the edit-copied-item popup (hosted by `ItemEditorWindow`).
// Thin by design: validation, outcome handling and the save itself live in
// `ItemEditValidation`, `ItemEditOutcomePresentation` and
// `ItemEditCoordinator` (all unit-tested); this view only wires them to
// controls.
//
// Keyboard (T-EDIT14): every button is an AppKit `KeyboardFocusableButton`
// (`EditorKeyboardControls.swift` explains why SwiftUI buttons can't be Tab
// stops by default); the lossy warning is an inline row, not a system alert,
// so its buttons are Tab stops too and Esc always means Go Back.

import ClipnestCore
import ClipnestViewModels
import SwiftUI

struct ItemEditorView: View {
  let mode: ItemEditMode
  /// True when the stored rich text can't be fully represented in the editor.
  let isLossy: Bool
  let initial: NSAttributedString
  let save: @MainActor (EditorOutput) async -> ItemEditOutcome
  let onSaved: @MainActor () -> Void
  let onCancel: () -> Void

  @StateObject private var controller: RichTextEditorController
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showLossyConfirmation = false

  init(
    mode: ItemEditMode,
    isLossy: Bool,
    initial: NSAttributedString,
    save: @escaping @MainActor (EditorOutput) async -> ItemEditOutcome,
    onSaved: @escaping @MainActor () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.mode = mode
    self.isLossy = isLossy
    self.initial = initial
    self.save = save
    self.onSaved = onSaved
    self.onCancel = onCancel
    _controller = StateObject(wrappedValue: RichTextEditorController(initialText: initial.string))
  }

  private var isRecognizedText: Bool {
    if case .recognizedText = mode { return true }
    return false
  }

  private var canSave: Bool {
    !isSaving && ItemEditValidation.canSave(plainText: controller.plainText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(mode.title).font(.headline)

      if !isRecognizedText {
        formattingToolbar
      }

      RichTextEditorView(
        controller: controller, initial: initial, isRichText: !isRecognizedText,
        onCancel: onCancel
      )
      .frame(minHeight: 200)
      .overlay {
        RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3))
      }

      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.callout)
          .textSelection(.enabled)
      }

      if showLossyConfirmation {
        lossyRow
      } else {
        buttonRow
      }
    }
    .padding(20)
    .frame(width: 360)
    .onChange(of: errorMessage) { _, message in
      // A message appearing doesn't move focus; say it out loud.
      if let message { EditorAnnouncer.announce(message) }
    }
  }

  private var buttonRow: some View {
    HStack {
      Spacer()
      EditorButton(
        identifier: ItemEditControl.cancel.rawValue, accessibilityLabel: ItemEditStrings.cancel,
        title: ItemEditStrings.cancel, keyEquivalent: EditorKeyEquivalent.escape,
        action: onCancel)
      EditorButton(
        identifier: ItemEditControl.save.rawValue, accessibilityLabel: ItemEditStrings.save,
        title: ItemEditStrings.save, isEnabled: canSave,
        keyEquivalent: EditorKeyEquivalent.returnKey, activatesOnCommandReturn: true,
        action: saveTapped)
    }
  }

  /// Inline replacement for the old system alert: Go Back (Esc) / Save Anyway,
  /// neither a default button (Return presses the focused one), both Tab stops
  /// with distinct accessibility labels.
  private var lossyRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(ItemEditStrings.lossyWarning).font(.callout)
      HStack {
        Spacer()
        EditorButton(
          identifier: ItemEditControl.goBack.rawValue,
          accessibilityLabel: ItemEditStrings.goBackAccessibilityLabel,
          title: ItemEditStrings.goBack, accessibilityHelp: ItemEditStrings.lossyWarning,
          keyEquivalent: EditorKeyEquivalent.escape, takesInitialFocus: true,
          action: goBack)
        EditorButton(
          identifier: ItemEditControl.saveAnyway.rawValue,
          accessibilityLabel: ItemEditStrings.saveAnywayAccessibilityLabel,
          title: ItemEditStrings.saveAnyway, isEnabled: !isSaving, action: performSave)
      }
    }
  }

  private var formattingToolbar: some View {
    HStack(spacing: 6) {
      toolbarButton(.bold, symbol: "bold", label: ItemEditStrings.boldLabel, key: "B", trait: .bold)
      toolbarButton(
        .italic, symbol: "italic", label: ItemEditStrings.italicLabel, key: "I", trait: .italic)
      toolbarButton(
        .underline, symbol: "underline", label: ItemEditStrings.underlineLabel, key: "U",
        trait: .underline)
      Spacer()
    }
  }

  private func toolbarButton(
    _ control: ItemEditControl, symbol: String, label: String, key: String,
    trait: MacEditableRichText.FormatTrait
  ) -> some View {
    EditorButton(
      identifier: control.rawValue, accessibilityLabel: label, symbol: symbol,
      help: ItemEditStrings.shortcutHint(
        label: label, key: key, modifier: ItemEditStrings.macShortcutModifier),
      isToggle: true, isOn: controller.activeTraits.contains(trait),
      action: { controller.toggle(trait) })
  }

  private func goBack() {
    showLossyConfirmation = false
    controller.focusEditor()
  }

  private func saveTapped() {
    guard canSave else { return }
    if isLossy {
      showLossyConfirmation = true
    } else {
      performSave()
    }
  }

  private func performSave() {
    guard !isSaving, let snapshot = controller.snapshot() else { return }
    isSaving = true
    showLossyConfirmation = false
    errorMessage = nil
    let recognized = isRecognizedText
    Task { @MainActor in
      let outcome: ItemEditOutcome
      if let output = await Self.makeOutput(snapshot, recognizedText: recognized) {
        outcome = await save(output)
      } else {
        // RTF serialization failed: surface it, never save an empty blob.
        outcome = .failed(message: ItemEditStrings.saveFailed)
      }
      let presentation = ItemEditOutcomePresentation(outcome: outcome)
      isSaving = false
      errorMessage = presentation.errorMessage
      if presentation.refreshList { onSaved() }
      if presentation.closesEditor { onCancel() }
    }
  }

  /// Builds the save payload. RTF serialization runs off the main actor on
  /// the immutable snapshot; recognized text is plain (trimmed, no blob).
  /// Returns nil when RTF serialization fails.
  private static func makeOutput(
    _ snapshot: RichTextEditorController.Snapshot, recognizedText: Bool
  ) async -> EditorOutput? {
    if recognizedText {
      return EditorOutput(
        plainText: snapshot.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
        hasFormatting: false, richBlob: Data())
    }
    let rtf = await Task.detached(priority: .utility) {
      MacEditableRichText.rtf(from: snapshot.attributed)
    }.value
    // Never save an empty blob: every such failure would share sha256("").
    guard let rtf, !rtf.isEmpty else { return nil }
    return EditorOutput(
      plainText: snapshot.plainText, hasFormatting: snapshot.hasFormatting, richBlob: rtf)
  }
}
