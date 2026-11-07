// SnippetFormView.swift
//
// Plan task T23: the Snippets tab's create/edit form. One form serves both
// create and edit — `SnippetFormMode` says which, and pre-fills the fields
// when editing. Deliberately simple per the task's own "don't over-design"
// instruction.
//
// T23 fix round, item 1: no longer presented as a `.sheet()` on `PickerPanel`
// — see `SnippetEditorWindow.swift`'s doc comment for why that couldn't
// receive typed input or ⌘V paste, and how this is hosted instead.
//
// T23 fix round (field correction): the form shows exactly **two** fields —
// **Tag** (a single-line name/label — the snippet's identifier) and
// **Body** (multiline content). There is no separate "Title" field. `Tag`
// maps onto the domain model's existing `Snippet.title` (already the
// field every other part of the app — `SnippetRow`, search — treats as the
// snippet's primary label, so this is a UI-label rename, not a new concept).
// The Tag is ALSO stored as `Snippet.keyword` (see `save()`), so it doubles
// as the expansion keyword — typing the Tag + ⌥⌘E replaces it with the Body
// (`SnippetExpander`). No schema change (both fields already exist).
// `SnippetFormMode.createFromClip(_:)` prefills **Body** with a copied
// item's content ("Save as Snippet"); the user fills in the Tag.
//
// Keyboard (T-EDIT15), same rules as the item editor (`ItemEditorView`): the
// Tag field takes the initial focus; Tab / Shift+Tab walk Tag, Body, Cancel,
// Save and wrap (a disabled Save is skipped; `SnippetEditFocusOrder` is the
// shared definition, the window rebuilds the key-view loop geometrically).
// The Body is the item editor's `EditorTextView` in plain-text mode (Tab moves
// focus, ⌥Tab types a tab, Esc cancels) and the buttons are
// `KeyboardFocusableButton`s, so they are Tab stops even with System
// Settings -> Keyboard navigation off. Return in the Tag saves, Return in the
// Body is a newline, ⌘Return saves from anywhere, Esc cancels.

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI

// P5 (Phase 3, Linux port): `SnippetFormMode` — "which mode `SnippetFormView`
// is presenting: a fresh, empty form (`.create`), a fresh form with `Body`
// pre-filled from a `ClipItem`'s content ('Save as Snippet', T23 fix round
// item 2), or an existing snippet's fields pre-filled for editing (`.edit`)"
// — moved to `ClipnestViewModels/UI/Picker/SnippetFormMode.swift`:
// `PickerViewModel.presentSnippetEditor`/`presentCreateSnippetForm()`/
// `presentEditSnippetForm(_:)`/`presentSaveAsSnippetForm(from:)` are hard
// compile dependencies of the now cross-platform `PickerViewModel`, while
// this `View` stays macOS/SwiftUI-only. Pure code motion; no behavior
// change.

struct SnippetFormView: View {
  let mode: SnippetFormMode
  /// T-SNIPFB1: inline error for a tag already used by another snippet
  /// (`PickerViewModel.snippetTagError`), or nil if it can be saved.
  let tagError: (_ tag: String) -> String?
  /// The (rebindable) expand shortcut, shown in the Tag helper text.
  let expandShortcut: String
  let onSave: (_ title: String, _ body: String, _ keyword: String?) -> Void
  let onCancel: () -> Void

  // Local, editable copies of the form fields — a `Snippet` (or nothing,
  // for `.create`) seeds the initial values once, at construction; the
  // user edits these freely and nothing round-trips to the store until
  // "Save" is pressed. `tag` maps onto `Snippet.title` at save time — see
  // the file's doc comment. The Body's text lives in the text view; its
  // controller mirrors it (`bodyController.plainText`).
  @State private var tag: String
  @StateObject private var bodyController: RichTextEditorController
  private let initialBody: NSAttributedString
  @FocusState private var tagFocused: Bool

  init(
    mode: SnippetFormMode,
    tagError: @escaping (String) -> String?,
    expandShortcut: String,
    onSave: @escaping (String, String, String?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.mode = mode
    self.tagError = tagError
    self.expandShortcut = expandShortcut
    self.onSave = onSave
    self.onCancel = onCancel
    let initialTag: String
    let initialBodyText: String
    switch mode {
    case .create:
      initialTag = ""
      initialBodyText = ""
    case .createFromClip(let prefillBody):
      initialTag = ""
      initialBodyText = prefillBody
    case .edit(let snippet):
      initialTag = snippet.title
      initialBodyText = snippet.body
    }
    _tag = State(initialValue: initialTag)
    initialBody = NSAttributedString(
      string: initialBodyText, attributes: MacEditableRichText.defaultAttributes)
    _bodyController = StateObject(
      wrappedValue: RichTextEditorController(initialText: initialBodyText))
  }

  /// Both fields are required — a snippet needs a name to find it by and
  /// content to be worth pasting.
  private var isSaveDisabled: Bool {
    tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || bodyController.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || currentTagError != nil
  }

  private var currentTagError: String? { tagError(tag) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(SnippetEditStrings.title(isNew: mode.isNew))
        .font(.headline)

      TextField(SnippetEditStrings.tagLabel, text: $tag)
        .textFieldStyle(.roundedBorder)
        .focused($tagFocused)
        .accessibilityLabel(SnippetEditStrings.tagLabel)
        .accessibilityIdentifier(SnippetEditControl.tag.rawValue)
        // Return in the Tag saves (when enabled); in the Body it is a newline.
        .onSubmit { if !isSaveDisabled { save() } }

      let note = SnippetTagValidation.fieldNote(
        error: currentTagError, expandShortcut: expandShortcut)
      Text(note.text)
        .font(.caption)
        .foregroundStyle(note.isError ? Color.red : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)

      RichTextEditorView(
        controller: bodyController, initial: initialBody, isRichText: false,
        onCancel: onCancel, identifier: SnippetEditControl.body.rawValue,
        accessibilityLabel: SnippetEditStrings.bodyLabel, takesInitialFocus: false
      )
      .frame(minHeight: 160)
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.secondary.opacity(0.3))
      }

      HStack {
        Spacer()
        EditorButton(
          identifier: SnippetEditControl.cancel.rawValue,
          accessibilityLabel: ItemEditStrings.cancel, title: ItemEditStrings.cancel,
          keyEquivalent: EditorKeyEquivalent.escape, action: onCancel)
        EditorButton(
          identifier: SnippetEditControl.save.rawValue,
          accessibilityLabel: ItemEditStrings.save, title: ItemEditStrings.save,
          isEnabled: !isSaveDisabled, keyEquivalent: EditorKeyEquivalent.returnKey,
          activatesOnCommandReturn: true, action: save)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear {
      // Focus the Tag field when the editor opens. Deferred a tick so the
      // hosting `SnippetEditorWindow` has become key first — a `.focused`
      // request made before the window is key doesn't take.
      DispatchQueue.main.async { tagFocused = true }
    }
  }

  private func save() {
    guard !isSaveDisabled else { return }
    let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = bodyController.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    // The Tag is BOTH the snippet's label (`title`) and its expansion
    // keyword (`keyword`): typing the Tag in any app, selecting it, and
    // pressing the expand hotkey (⌥⌘E) replaces it with the Body (see
    // `SnippetExpander`/`findByKeyword`). Passing the Tag as the keyword is
    // what makes "tag apply" work — leaving it `nil` (the previous behavior)
    // meant `findByKeyword` never matched any snippet, so expansion did
    // nothing.
    onSave(trimmedTag, trimmedBody, trimmedTag)
  }
}
