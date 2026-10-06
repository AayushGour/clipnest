// SnippetEditorWindow.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): closes the ONE unfilled
// seam that made every snippet-editing feature read-only on Linux —
// `PickerViewModel.presentSnippetEditor` (`ClipnestViewModels/UI/Picker
// /PickerViewModel.swift`) is an injected `(SnippetFormMode) -> Void`
// defaulting to a no-op; macOS injects a real presenter in `AppEnvironment
// .init` (`ClipnestApp/Sources/App/AppEnvironment.swift`); Linux never did.
// `saveHighlightedAsSnippet()`/`presentCreateSnippetForm()`/
// `presentEditSnippetForm(_:)` already exist, unchanged, in the shared view
// model — this type is purely a GTK4 presenter for them, the direct
// counterpart of macOS's identically-named `SnippetEditorWindow`
// (`ClipnestApp/Sources/UI/Picker/SnippetEditorWindow.swift` +
// `SnippetFormView.swift`, combined into one type here since GTK has no
// separate "hosted SwiftUI view" concept to split out).
//
// Field set/validation/labels/title mirror macOS EXACTLY (per this task's
// spec — "mirror them, don't invent"):
//   - Two fields: "Tag" (single-line, placeholder text — matches
//     `TextField("Tag", text:)`'s in-field placeholder, no separate label
//     row) and "Body" (multi-line — `GtkTextView`, GTK4's only multi-line
//     text-input widget, the counterpart of SwiftUI's `TextEditor`).
//   - Validation: Save is disabled unless BOTH fields are non-empty after
//     trimming whitespace/newlines (`SnippetFormValidation.isSaveEnabled`,
//     mirroring `SnippetFormView.isSaveDisabled` exactly) — re-checked live
//     on every keystroke in either field.
//   - Buttons: "Cancel", "Save" — identical labels, identical order.
//   - Title: "New Snippet" / "Edit Snippet" (`SnippetFormMode.isNew`) — set
//     as BOTH the window's actual title bar text (`gtk_window_set_title`)
//     AND an in-content heading label, matching macOS doing both
//     (`SnippetEditorWindow.show`'s `title = ...` AND `SnippetFormView
//     .body`'s `Text(mode.isNew ? ... )` heading).
//
// Deliberately NOT mirrored (impossible on this platform, not a missed
// requirement): macOS's side-by-side pair placement beside `PickerPanel`
// (`WindowPlacement.pairLayout`) — GTK4 removed `gtk_window_move` from the
// portable `GtkWindow` API entirely (see `PickerWindow.swift`'s top
// "WINDOW PLACEMENT" doc comment for the same limitation already documented
// there). This window falls back to the window manager's own placement.
//
// Lifetime: a single, reused instance for the app's whole run — mirrors
// `SettingsWindow`'s exact "built once, shown/hidden via
// `gtk_window_set_hide_on_close`" shape, itself the GTK counterpart of
// macOS's `isReleasedWhenClosed = false`. `show(mode:onSave:onClose:)` can
// be called again after a previous close; nothing here is torn down.
//
// Close path: Save, Cancel, and the titlebar's own close button all route
// through exactly ONE place — `handleCloseRequest()`, connected to
// `GtkWindow::close-request` — so `onClose` fires exactly once per open,
// regardless of which of the three the user used. Save/Cancel both simply
// call `gtk_window_close(window)` (which itself emits `close-request`)
// rather than hiding the window directly, so there is no second,
// independently-triggered close path to keep in sync — the exact class of
// bug `PickerWindow.dismiss()`'s own doc comment describes at length for a
// DIFFERENT window this task must not touch; this file sidesteps it
// structurally by only ever having the one path.
import CGtk4
import ClipnestCore
import ClipnestViewModels

/// See this file's top doc comment. `@unchecked Sendable` for the identical,
/// documented reason `PickerWindow`/`SettingsWindow` already carry the same
/// annotation — every access happens on the single GTK thread (see
/// `PickerWindow.swift`'s top "ACTOR ISOLATION" doc comment).
public final class SnippetEditorWindow: @unchecked Sendable {
  static let defaultWidth: Int32 = 380
  static let defaultHeight: Int32 = 460
  static let formMargin: Int32 = 20
  static let formSpacing: Int32 = 12
  static let bodyMinHeight: Int32 = 160
  static let buttonSpacing: Int32 = 8

  let window: OpaquePointer
  let headingLabel: OpaquePointer
  let tagEntry: OpaquePointer
  let bodyTextView: OpaquePointer
  let bodyBuffer: OpaquePointer
  let cancelButton: OpaquePointer
  let saveButton: OpaquePointer

  /// Set fresh on every `show(mode:onSave:onClose:)` call; cleared once
  /// `handleCloseRequest()` fires them, so a stale closure from a previous
  /// open can never run twice. See this file's top "Close path" doc
  /// comment.
  private var onSave: ((_ title: String, _ body: String, _ keyword: String?) -> Void)?
  private var onClose: (() -> Void)?

  public init() {
    window = gtk_window_new()
    headingLabel = gtk_label_new(nil)
    tagEntry = gtk_entry_new()
    bodyTextView = gtk_text_view_new()
    bodyBuffer = gtk_text_view_get_buffer(bodyTextView)
    cancelButton = gtk_button_new_with_label("Cancel")
    saveButton = gtk_button_new_with_label("Save")

    gtk_window_set_default_size(window, Self.defaultWidth, Self.defaultHeight)
    // Clicking the titlebar close button hides rather than destroys the
    // window — this instance is reused for the app's whole lifetime,
    // mirroring `SettingsWindow.init`'s identical call/doc comment.
    gtk_window_set_hide_on_close(window, 1)

    buildLayout()
    connectSignals()
  }

  /// Shows the editor, prefilled per `mode` (see `SnippetFormMode`),
  /// activating this window (a real, titled, closable `GtkWindow` — safe to
  /// activate here even though the picker itself must never steal focus;
  /// see macOS's `SnippetEditorWindow.swift` top doc comment for why that
  /// distinction holds on this platform too: the user explicitly asked to
  /// type into a form).
  ///
  /// - Parameters:
  ///   - mode: which form state to present.
  ///   - onSave: called with the trimmed tag/body once the user presses
  ///     Save (Save is disabled/unreachable otherwise — see
  ///     `updateSaveEnabled()`). The Tag is passed as BOTH `title` and
  ///     `keyword`, matching `SnippetFormView.save()` exactly (the Tag
  ///     doubles as the expansion keyword). This type has no opinion on
  ///     create vs. update — same contract as macOS's `SnippetEditorWindow
  ///     .show`, whose caller decides that by switching on the very `mode`
  ///     it passed in.
  ///   - onClose: called exactly once, whenever this window closes for any
  ///     reason. See this file's top "Close path" doc comment.
  ///   - transientParent: the picker's `GtkWindow`, so the window manager
  ///     stacks this editor ABOVE it and centres it there.
  ///
  ///     Not optional politeness — without it this window renders BEHIND the
  ///     picker and a user who clicks "+" sees nothing happen. `PickerWindow`
  ///     sets `_NET_WM_WINDOW_TYPE_UTILITY` on itself (so mutter honours our
  ///     placement instead of applying its own heuristics), and a utility
  ///     window is kept above ordinary toplevels. This editor is an ordinary
  ///     toplevel, so it was correctly stacked underneath. Declaring it
  ///     transient-for the picker is what tells the WM these two belong
  ///     together; `gtk_window_set_modal` then matches macOS, where the
  ///     snippet form is a sheet over the picker rather than a peer window.
  public func show(
    mode: SnippetFormMode,
    transientParent: OpaquePointer?,
    onSave: @escaping (_ title: String, _ body: String, _ keyword: String?) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.onSave = onSave
    self.onClose = onClose
    let title = mode.isNew ? "New Snippet" : "Edit Snippet"
    gtk_window_set_title(window, title)
    gtk_label_set_markup(headingLabel, "<b>\(PangoMarkup.escape(title))</b>")
    populateFields(for: mode)
    updateSaveEnabled()
    if let transientParent {
      gtk_window_set_transient_for(window, transientParent)
      gtk_window_set_modal(window, 1)
    }
    gtk_widget_set_visible(window, 1)
    gtk_window_present(window)
    gtk_widget_grab_focus(tagEntry)
  }

  private func populateFields(for mode: SnippetFormMode) {
    switch mode {
    case .create:
      gtk_editable_set_text(tagEntry, "")
      setBodyText("")
    case .createFromClip(let prefillBody):
      gtk_editable_set_text(tagEntry, "")
      setBodyText(prefillBody)
    case .edit(let snippet):
      gtk_editable_set_text(tagEntry, snippet.title)
      setBodyText(snippet.body)
    }
  }

  private func buildLayout() {
    let outerBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, Self.formSpacing)
    gtk_widget_set_margin_start(outerBox, Self.formMargin)
    gtk_widget_set_margin_end(outerBox, Self.formMargin)
    gtk_widget_set_margin_top(outerBox, Self.formMargin)
    gtk_widget_set_margin_bottom(outerBox, Self.formMargin)

    gtk_label_set_xalign(headingLabel, 0)
    gtk_box_append(outerBox, headingLabel)

    // Matches `TextField("Tag", text:)` — "Tag" is placeholder text shown
    // INSIDE the field, not a separate label row (see this file's top doc
    // comment).
    gtk_entry_set_placeholder_text(tagEntry, "Tag")
    gtk_box_append(outerBox, tagEntry)

    let bodyScroller: OpaquePointer = gtk_scrolled_window_new()
    gtk_scrolled_window_set_policy(bodyScroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_widget_set_size_request(bodyScroller, -1, Self.bodyMinHeight)
    gtk_widget_set_vexpand(bodyScroller, 1)
    gtk_widget_add_css_class(bodyScroller, "snippet-body-frame")
    gtk_text_view_set_wrap_mode(bodyTextView, GTK_WRAP_WORD_CHAR)
    gtk_scrolled_window_set_child(bodyScroller, bodyTextView)
    gtk_box_append(outerBox, bodyScroller)

    let buttonBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, Self.buttonSpacing)
    gtk_widget_set_halign(buttonBox, GTK_ALIGN_END)
    gtk_box_append(buttonBox, cancelButton)
    gtk_widget_add_css_class(saveButton, "suggested-action")
    gtk_box_append(buttonBox, saveButton)
    gtk_box_append(outerBox, buttonBox)

    gtk_window_set_child(window, outerBox)
  }

  private func connectSignals() {
    gtkConnect(
      tagEntry, signal: "changed", context: self,
      callback: unsafeBitCast(snippetFieldChangedTrampoline, to: GCallback.self))
    gtkConnect(
      bodyBuffer, signal: "changed", context: self,
      callback: unsafeBitCast(snippetFieldChangedTrampoline, to: GCallback.self))
    gtkConnect(
      cancelButton, signal: "clicked", context: self,
      callback: unsafeBitCast(snippetCancelClickedTrampoline, to: GCallback.self))
    gtkConnect(
      saveButton, signal: "clicked", context: self,
      callback: unsafeBitCast(snippetSaveClickedTrampoline, to: GCallback.self))
    gtkConnect(
      window, signal: "close-request", context: self,
      callback: unsafeBitCast(snippetCloseRequestTrampoline, to: GCallback.self))
  }

  func handleFieldChanged() {
    updateSaveEnabled()
  }

  func handleCancelClicked() {
    gtk_window_close(window)
  }

  func handleSaveClicked() {
    let tag = currentTagText().trimmingCharacters(in: .whitespacesAndNewlines)
    let body = currentBodyText().trimmingCharacters(in: .whitespacesAndNewlines)
    guard SnippetFormValidation.isSaveEnabled(tag: tag, body: body) else { return }
    // The Tag doubles as the expansion keyword — matches
    // `SnippetFormView.save()`'s `onSave(trimmedTag, trimmedBody, trimmedTag)`
    // exactly.
    onSave?(tag, body, tag)
    gtk_window_close(window)
  }

  /// `GtkWindow::close-request` — fires for Save/Cancel (both call
  /// `gtk_window_close`, which emits this) AND the titlebar's own close
  /// button, making this the one place `onClose` fires, exactly once. `0`
  /// (`GDK_EVENT_PROPAGATE`) lets GTK's default handling proceed —
  /// `gtk_window_set_hide_on_close(window, 1)` (`init`) means that default
  /// is "hide," not "destroy," so this instance survives to be shown again.
  func handleCloseRequest() -> Int32 {
    onClose?()
    onClose = nil
    onSave = nil
    return 0
  }

  private func updateSaveEnabled() {
    let enabled = SnippetFormValidation.isSaveEnabled(
      tag: currentTagText(), body: currentBodyText())
    gtk_widget_set_sensitive(saveButton, enabled ? 1 : 0)
  }

  private func currentTagText() -> String {
    String(cString: gtk_editable_get_text(tagEntry))
  }

  private func setBodyText(_ text: String) {
    gtk_text_buffer_set_text(bodyBuffer, text, Int32(text.utf8.count))
  }

  private func currentBodyText() -> String {
    var start = GtkTextIter()
    var end = GtkTextIter()
    gtk_text_buffer_get_start_iter(bodyBuffer, &start)
    gtk_text_buffer_get_end_iter(bodyBuffer, &end)
    guard let cString = gtk_text_buffer_get_text(bodyBuffer, &start, &end, 0) else { return "" }
    defer { g_free(cString) }
    return String(cString: cString)
  }
}

/// `GtkEditable::changed` (the Tag entry) / `GtkTextBuffer::changed` (the
/// Body buffer) — both `void (*)(<widget>, gpointer)`, identical shape, so
/// one trampoline serves either connection; `handleFieldChanged()` re-reads
/// both fields regardless of which one changed.
private let snippetFieldChangedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: SnippetEditorWindow.self) else { return }
      window.handleFieldChanged()
    }

/// `GtkButton::clicked` (Cancel) — `void (*)(GtkButton*, gpointer)`.
private let snippetCancelClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: SnippetEditorWindow.self) else { return }
      window.handleCancelClicked()
    }

/// `GtkButton::clicked` (Save) — `void (*)(GtkButton*, gpointer)`.
private let snippetSaveClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: SnippetEditorWindow.self) else { return }
      window.handleSaveClicked()
    }

/// `GtkWindow::close-request` — `gboolean (*)(GtkWindow*, gpointer)`.
private let snippetCloseRequestTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Int32 = { _, data in
      guard let window = unretainedContext(data, as: SnippetEditorWindow.self) else { return 0 }
      return window.handleCloseRequest()
    }
