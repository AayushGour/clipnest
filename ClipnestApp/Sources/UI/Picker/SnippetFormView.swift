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

import ClipnestCore
import SwiftUI

/// Which mode `SnippetFormView` is presenting: a fresh, empty form
/// (`.create`), a fresh form with `Body` pre-filled from a `ClipItem`'s
/// content ("Save as Snippet", T23 fix round item 2), or an existing
/// snippet's fields pre-filled for editing (`.edit`).
enum SnippetFormMode {
  case create
  case createFromClip(String)
  case edit(Snippet)

  var isNew: Bool {
    switch self {
    case .create, .createFromClip: return true
    case .edit: return false
    }
  }
}

struct SnippetFormView: View {
  let mode: SnippetFormMode
  let onSave: (_ title: String, _ body: String, _ keyword: String?) -> Void
  let onCancel: () -> Void

  // Local, editable copies of the form fields — a `Snippet` (or nothing,
  // for `.create`) seeds the initial values once, at construction; the
  // user edits these freely and nothing round-trips to the store until
  // "Save" is pressed. `tag` maps onto `Snippet.title` at save time — see
  // the file's doc comment. `bodyText` (not `body`) to avoid colliding
  // with SwiftUI's required `var body: some View` below.
  @State private var tag: String
  @State private var bodyText: String
  @FocusState private var tagFocused: Bool

  init(
    mode: SnippetFormMode,
    onSave: @escaping (String, String, String?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.mode = mode
    self.onSave = onSave
    self.onCancel = onCancel
    switch mode {
    case .create:
      _tag = State(initialValue: "")
      _bodyText = State(initialValue: "")
    case .createFromClip(let prefillBody):
      _tag = State(initialValue: "")
      _bodyText = State(initialValue: prefillBody)
    case .edit(let snippet):
      _tag = State(initialValue: snippet.title)
      _bodyText = State(initialValue: snippet.body)
    }
  }

  /// Both fields are required — a snippet needs a name to find it by and
  /// content to be worth pasting.
  private var isSaveDisabled: Bool {
    tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(mode.isNew ? "New Snippet" : "Edit Snippet")
        .font(.headline)

      TextField("Tag", text: $tag)
        .textFieldStyle(.roundedBorder)
        .focused($tagFocused)

      TextEditor(text: $bodyText)
        .font(.body)
        .frame(minHeight: 160)
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.3))
        }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaveDisabled)
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
    let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
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
