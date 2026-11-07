// ItemEditorWindow.swift
//
// T-EDIT9: the GTK4 popup for editing a copied item (`PickerViewModel
// .presentItemEditor`), the counterpart of macOS's `ItemEditorWindow`. A
// `GtkTextView` over a tag table, a Bold / Italic / Underline toolbar
// (content mode only), an inline message line, and a Cancel / Save row that
// is swapped for an inline "can't keep some formatting" confirmation when the
// item is lossy. Modelled on `SnippetEditorWindow` (shared layout constants,
// closure-context trampolines, one reused instance) -- see its doc comment
// for the lifetime and transient-parent rationale, which apply unchanged.
//
// WHAT EACH OUTCOME DOES is not decided here: `ItemEditOutcomePresentation`
// (ClipnestViewModels) is the one rule shared with macOS -- message, refresh,
// close.
//
// Threading: every GTK call is on the GTK thread (== main actor here).
// Serialising the buffer into HTML (`blobFromRuns`) runs in
// `Task.detached(priority: .utility)` on an immutable snapshot of the runs.
//
// Wayland: the save closure writes the system clipboard, and mutter drops a
// clipboard write from a client without keyboard focus. So the window is only
// closed AFTER `save` returns, and the hide itself is deferred to a GLib idle
// (never inside `close-request`), like every other window handoff here.
//
// Keyboard (T-EDIT14): Tab order is widget order (Bold, Italic, Underline,
// editor, Cancel, Save); chords are in `EditorKeyAction`.
//
// LIMITATION: the toolbar toggles a style on the current SELECTION only. With
// no selection the buttons do nothing (no "typing style" state is kept).
import CGtk4
import ClipnestCore
import ClipnestViewModels
import Foundation

public final class ItemEditorWindow: @unchecked Sendable {
  let window: OpaquePointer
  let headingLabel: OpaquePointer
  let messageLabel: OpaquePointer
  let toolbarBox: OpaquePointer
  let textView: OpaquePointer
  let buffer: OpaquePointer
  let saveRow: OpaquePointer
  let cancelButton: OpaquePointer
  let saveButton: OpaquePointer
  let lossyRow: OpaquePointer
  let lossyLabel: OpaquePointer
  let saveAnywayButton: OpaquePointer
  let goBackButton: OpaquePointer

  private let blobFromRuns: @Sendable ([StyledRun]) -> Data

  /// Tags created so far, by `ItemEditorTagNames` name.
  var tags: [String: OpaquePointer] = [:]

  /// The Bold / Italic / Underline toggle buttons, by `ItemEditorTagNames`
  /// name. Their pressed state mirrors the selection (`syncStyleButtons`).
  var styleButtons: [String: OpaquePointer] = [:]

  private var mode: ItemEditMode?
  private var isLossy = false
  private var save: (@MainActor (EditorOutput) async -> ItemEditOutcome)?
  private var onSaved: (@MainActor () -> Void)?
  private var onClose: (() -> Void)?
  /// A save is in flight; blocks a second Save and re-entrant closes.
  private var isSaving = false
  /// A close is scheduled or running; the re-entrancy guard for
  /// `close-request`.
  private var isClosing = false

  /// - Parameter blobFromRuns: serialises styled runs into the stored
  ///   rich-text blob. Required (no default): `ClipnestGTK` does not depend
  ///   on `ClipnestPlatformLinux`, so the composition root supplies it, and a
  ///   missing wiring is a build error rather than a silent plain-text save.
  public init(blobFromRuns: @escaping @Sendable ([StyledRun]) -> Data) {
    self.blobFromRuns = blobFromRuns
    window = gtk_window_new()
    headingLabel = gtk_label_new(nil)
    messageLabel = gtk_label_new(nil)
    toolbarBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, SnippetEditorWindow.buttonSpacing)
    textView = gtk_text_view_new()
    buffer = gtk_text_view_get_buffer(textView)
    saveRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, SnippetEditorWindow.buttonSpacing)
    cancelButton = gtk_button_new_with_label(ItemEditStrings.cancel)
    saveButton = gtk_button_new_with_label(ItemEditStrings.save)
    lossyRow = gtk_box_new(GTK_ORIENTATION_VERTICAL, SnippetEditorWindow.buttonSpacing)
    lossyLabel = gtk_label_new(ItemEditStrings.lossyWarning)
    saveAnywayButton = gtk_button_new_with_label(ItemEditStrings.saveAnyway)
    goBackButton = gtk_button_new_with_label(ItemEditStrings.goBack)

    gtk_window_set_default_size(
      window, SnippetEditorWindow.defaultWidth, SnippetEditorWindow.defaultHeight)
    buildLayout()
    connectSignals()
  }

  /// Whether the editor is currently on screen.
  public var isVisible: Bool { gtk_widget_get_visible(window) != 0 }

  /// Brings an already-open editor forward without touching its callbacks.
  public func bringToFront() {
    gtk_window_present(window)
  }

  /// Shows the editor for `mode`, prefilled from `initial`.
  ///
  /// At most one editor is open: if this one is already visible it is only
  /// brought forward -- the open editor's `onClose` is never replaced.
  ///
  /// - Parameters:
  ///   - transientParent: the picker's `GtkWindow`. Required for the same
  ///     reason as `SnippetEditorWindow.show`: without it the editor opens
  ///     BEHIND the picker's utility-type window.
  ///   - save: persists the edit; the window shows its `ItemEditOutcome` per
  ///     `ItemEditOutcomePresentation`. Awaited with the popup still open, so
  ///     the clipboard write it may perform happens while this window holds
  ///     keyboard focus.
  ///   - onSaved: refresh the picker list (runs for `.saved` and `.failed`).
  ///   - onClose: runs exactly once per open, after the window is hidden.
  public func show(
    mode: ItemEditMode,
    initial: EditableRichText,
    transientParent: OpaquePointer?,
    save: @escaping @MainActor (EditorOutput) async -> ItemEditOutcome,
    onSaved: @escaping @MainActor () -> Void,
    onClose: @escaping () -> Void
  ) {
    guard !isVisible, !isClosing else {
      bringToFront()
      return
    }
    self.mode = mode
    self.isLossy = initial.isLossy && !isRecognizedText
    self.save = save
    self.onSaved = onSaved
    self.onClose = onClose
    isSaving = false

    gtk_window_set_title(window, mode.title)
    gtk_label_set_markup(headingLabel, "<b>\(PangoMarkup.escape(mode.title))</b>")
    gtk_widget_set_visible(toolbarBox, isRecognizedText ? 0 : 1)
    showMessage(nil)
    showSaveRow()
    load(initial, richText: !isRecognizedText)
    updateSaveEnabled()
    if let transientParent {
      gtk_window_set_transient_for(window, transientParent)
      gtk_window_set_modal(window, 1)
    }
    gtk_widget_set_visible(window, 1)
    gtk_window_present(window)
    gtk_widget_grab_focus(textView)
  }

  var isRecognizedText: Bool {
    if case .recognizedText = mode { return true }
    return false
  }

  // MARK: - Layout

  private func buildLayout() {
    let outerBox: OpaquePointer = gtk_box_new(
      GTK_ORIENTATION_VERTICAL, SnippetEditorWindow.formSpacing)
    gtk_widget_set_margin_start(outerBox, SnippetEditorWindow.formMargin)
    gtk_widget_set_margin_end(outerBox, SnippetEditorWindow.formMargin)
    gtk_widget_set_margin_top(outerBox, SnippetEditorWindow.formMargin)
    gtk_widget_set_margin_bottom(outerBox, SnippetEditorWindow.formMargin)

    gtk_label_set_xalign(headingLabel, 0)
    gtk_box_append(outerBox, headingLabel)

    // GtkToggleButtons: GTK exposes their active state to Orca as "pressed".
    for (label, tag, key) in [
      (ItemEditStrings.boldLabel, ItemEditorTagNames.bold, "B"),
      (ItemEditStrings.italicLabel, ItemEditorTagNames.italic, "I"),
      (ItemEditStrings.underlineLabel, ItemEditorTagNames.underline, "U"),
    ] {
      let button = gtk_toggle_button_new_with_label(label)
      gtk_widget_set_tooltip_text(
        button,
        ItemEditStrings.shortcutHint(
          label: label, key: key, modifier: ItemEditStrings.linuxShortcutModifier))
      gtkConnect(
        button, signal: "clicked",
        context: ClosureContext<Void> { [weak self] in self?.toggleStyle(tagNamed: tag) },
        callback: unsafeBitCast(itemEditorVoidSignalTrampoline, to: GCallback.self))
      gtk_box_append(toolbarBox, button)
      styleButtons[tag] = button
    }
    gtk_box_append(outerBox, toolbarBox)

    let scroller: OpaquePointer = gtk_scrolled_window_new()
    gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_widget_set_size_request(scroller, -1, SnippetEditorWindow.bodyMinHeight)
    gtk_widget_set_vexpand(scroller, 1)
    gtk_text_view_set_wrap_mode(textView, GTK_WRAP_WORD_CHAR)
    // Tab moves focus on (Bold ... editor, Cancel, Save); a literal tab is
    // Ctrl+Tab, see `EditorKeyAction`.
    gtk_text_view_set_accepts_tab(textView, 0)
    gtkSetAccessibleLabel(textView, ItemEditStrings.textLabel)
    gtk_scrolled_window_set_child(scroller, textView)
    gtk_box_append(outerBox, scroller)

    gtk_label_set_xalign(messageLabel, 0)
    gtk_label_set_wrap(messageLabel, 1)
    gtk_widget_add_css_class(messageLabel, "error")
    gtk_box_append(outerBox, messageLabel)

    gtk_widget_set_halign(saveRow, GTK_ALIGN_END)
    gtk_box_append(saveRow, cancelButton)
    gtk_widget_add_css_class(saveButton, "suggested-action")
    gtk_box_append(saveRow, saveButton)
    gtk_box_append(outerBox, saveRow)

    gtk_label_set_xalign(lossyLabel, 0)
    gtk_label_set_wrap(lossyLabel, 1)
    gtk_box_append(lossyRow, lossyLabel)
    let lossyButtons: OpaquePointer = gtk_box_new(
      GTK_ORIENTATION_HORIZONTAL, SnippetEditorWindow.buttonSpacing)
    gtk_widget_set_halign(lossyButtons, GTK_ALIGN_END)
    gtk_box_append(lossyButtons, goBackButton)
    gtk_widget_add_css_class(saveAnywayButton, "destructive-action")
    gtk_box_append(lossyButtons, saveAnywayButton)
    gtk_box_append(lossyRow, lossyButtons)
    gtk_widget_set_visible(lossyRow, 0)
    gtk_box_append(outerBox, lossyRow)

    gtk_window_set_child(window, outerBox)
  }

  private func connectSignals() {
    func connect(_ object: OpaquePointer, _ signal: String, _ action: @escaping () -> Void) {
      gtkConnect(
        object, signal: signal, context: ClosureContext<Void> { action() },
        callback: unsafeBitCast(itemEditorVoidSignalTrampoline, to: GCallback.self))
    }
    connect(buffer, "changed") { [weak self] in
      self?.updateSaveEnabled()
      self?.syncStyleButtons()
    }
    gtkConnect(
      buffer, signal: "mark-set", context: self,
      callback: unsafeBitCast(itemEditorMarkSetTrampoline, to: GCallback.self))
    let keyController: OpaquePointer = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(keyController, GTK_PHASE_CAPTURE)
    gtkConnect(
      keyController, signal: "key-pressed", context: self,
      callback: unsafeBitCast(itemEditorKeyPressedTrampoline, to: GCallback.self))
    gtk_widget_add_controller(window, keyController)
    connect(cancelButton, "clicked") { [weak self] in self?.requestClose() }
    connect(saveButton, "clicked") { [weak self] in self?.saveTapped() }
    connect(goBackButton, "clicked") { [weak self] in self?.showSaveRow() }
    connect(saveAnywayButton, "clicked") { [weak self] in self?.performSave() }
    gtkConnect(
      window, signal: "close-request", context: self,
      callback: unsafeBitCast(itemEditorCloseRequestTrampoline, to: GCallback.self))
  }

  // MARK: - State

  private func updateSaveEnabled() {
    let canSave = ItemEditValidation.canSave(plainText: currentText())
    gtk_widget_set_sensitive(saveButton, canSave && !isSaving ? 1 : 0)
  }

  private func setSavingUI(_ saving: Bool) {
    isSaving = saving
    gtk_widget_set_sensitive(cancelButton, saving ? 0 : 1)
    gtk_widget_set_sensitive(saveAnywayButton, saving ? 0 : 1)
    gtk_widget_set_sensitive(goBackButton, saving ? 0 : 1)
    // Text typed after the snapshot would be silently dropped on .saved.
    gtk_text_view_set_editable(textView, saving ? 0 : 1)
    updateSaveEnabled()
  }

  private func showMessage(_ message: String?) {
    gtk_label_set_text(messageLabel, message ?? "")
    gtk_widget_set_visible(messageLabel, message == nil ? 0 : 1)
  }

  private func showSaveRow() {
    gtk_widget_set_visible(lossyRow, 0)
    gtk_widget_set_visible(saveRow, 1)
    // Return outside the editor saves.
    gtk_window_set_default_widget(window, saveButton)
    gtk_widget_grab_focus(textView)
  }

  /// Focus lands on Go Back (the non-destructive choice), there is no default
  /// widget; Esc is Go Back (see `handleKeyPressed`).
  private func showLossyRow() {
    gtk_widget_set_visible(saveRow, 0)
    gtk_widget_set_visible(lossyRow, 1)
    // No default button while the warning is up: Return only presses the
    // focused button (Go Back first).
    gtk_window_set_default_widget(window, nil)
    gtk_widget_grab_focus(goBackButton)
  }

  private var isLossyRowShowing: Bool { gtk_widget_get_visible(lossyRow) != 0 }

  // MARK: - Keyboard

  /// `GtkEventControllerKey::key-pressed` on the window (capture phase), so
  /// Esc / Ctrl+Return work whichever widget has focus. Returns 1 when handled.
  func handleKeyPressed(keyval: UInt32, state: UInt32) -> Int32 {
    guard
      let action = EditorKeyAction.action(
        keyval: keyval, state: state,
        focusInEditor: gtkFocusIsWithin(window: window, widget: textView),
        isRichText: !isRecognizedText)
    else { return 0 }
    switch action {
    case .cancel:
      // An in-flight save is not interruptible (Wayland clipboard write needs
      // this window open), so Esc is consumed and ignored rather than left to
      // GTK, which would otherwise treat it as a stray key.
      if isLossyRowShowing {
        showSaveRow()
      } else if !isSaving {
        requestClose()
      }
    case .save:
      if !isLossyRowShowing { saveTapped() }
    case .insertTab:
      insertTab()
    case .toggleBold: toggleStyle(tagNamed: ItemEditorTagNames.bold)
    case .toggleItalic: toggleStyle(tagNamed: ItemEditorTagNames.italic)
    case .toggleUnderline: toggleStyle(tagNamed: ItemEditorTagNames.underline)
    }
    return 1
  }

  // MARK: - Save

  private func saveTapped() {
    guard !isSaving, gtk_widget_get_sensitive(saveButton) != 0 else { return }
    if isLossy {
      showLossyRow()
    } else {
      performSave()
    }
  }

  /// Snapshots the buffer on the GTK thread, builds the output off-main,
  /// awaits `save` with the window still open, then applies the outcome.
  private func performSave() {
    guard !isSaving, let save, mode != nil else { return }
    let recognized = isRecognizedText
    let text = currentText()
    let runs = recognized ? [] : currentRuns()
    let blobFromRuns = blobFromRuns
    setSavingUI(true)
    showMessage(nil)
    Task { @MainActor [weak self] in
      let output = await Task.detached(priority: .utility) {
        Self.output(text: text, runs: runs, recognizedText: recognized, blobFromRuns: blobFromRuns)
      }.value
      let outcome = await save(output)
      self?.apply(outcome)
    }
  }

  /// Pure: what a platform editor hands to the coordinator.
  /// Recognized text is plain (trimmed, no blob); content keeps the runs.
  static func output(
    text: String, runs: [StyledRun], recognizedText: Bool,
    blobFromRuns: @Sendable ([StyledRun]) -> Data
  ) -> EditorOutput {
    if recognizedText {
      return EditorOutput(
        plainText: text.trimmingCharacters(in: .whitespacesAndNewlines),
        hasFormatting: false, richBlob: Data())
    }
    return EditorOutput(
      plainText: text, hasFormatting: runs.contains { $0.hasFormatting },
      richBlob: blobFromRuns(runs))
  }

  @MainActor
  private func apply(_ outcome: ItemEditOutcome) {
    let presentation = ItemEditOutcomePresentation(outcome: outcome)
    setSavingUI(false)
    showMessage(presentation.errorMessage)
    if presentation.errorMessage != nil { showSaveRow() }
    if presentation.refreshList { onSaved?() }
    if presentation.closesEditor { requestClose() }
  }

  // MARK: - Close

  /// Asks the window to close; `close-request` is the one close path.
  private func requestClose() {
    gtk_window_close(window)
  }

  /// `GtkWindow::close-request`. Returns `true` (handled) always: the hide is
  /// deferred to an idle so the window is never hidden from inside this
  /// signal, and a second request while one is pending is swallowed.
  func handleCloseRequest() -> Int32 {
    guard !isClosing, !isSaving else { return 1 }
    isClosing = true
    g_idle_add_full(
      G_PRIORITY_DEFAULT_IDLE, itemEditorHideIdleTrampoline,
      retainedTrampolineContext(self), releaseTrampolineContextSingleArg)
    return 1
  }

  fileprivate func finishClose() {
    gtk_widget_set_visible(window, 0)
    let onClose = onClose
    self.onClose = nil
    save = nil
    onSaved = nil
    mode = nil
    isClosing = false
    onClose?()
  }
}

/// `void (*)(<instance>, gpointer)` for any parameterless signal
/// (`GtkButton::clicked`, `GtkTextBuffer::changed`).
private let itemEditorVoidSignalTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      unretainedContext(data, as: ClosureContext<Void>.self)?.perform(())
    }

/// `GtkTextBuffer::mark-set` -- `void (*)(GtkTextBuffer*, const GtkTextIter*,
/// GtkTextMark*, gpointer)`. Fires when the cursor / selection moves.
private let itemEditorMarkSetTrampoline:
  @convention(c) (OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, _, _, data in
      unretainedContext(data, as: ItemEditorWindow.self)?.syncStyleButtons()
    }

/// `GtkEventControllerKey::key-pressed` -- `gboolean (*)(controller, guint
/// keyval, guint keycode, GdkModifierType state, gpointer)`.
private let itemEditorKeyPressedTrampoline:
  @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) ->
    Int32 = { _, keyval, _, state, data in
      guard let window = unretainedContext(data, as: ItemEditorWindow.self) else { return 0 }
      return window.handleKeyPressed(keyval: keyval, state: state)
    }

/// `GtkWindow::close-request` -- `gboolean (*)(GtkWindow*, gpointer)`.
private let itemEditorCloseRequestTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Int32 = { _, data in
      guard let window = unretainedContext(data, as: ItemEditorWindow.self) else { return 1 }
      return window.handleCloseRequest()
    }

/// One-shot idle (`G_SOURCE_REMOVE`) that actually hides the window.
private let itemEditorHideIdleTrampoline: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
  data in
  unretainedContext(data, as: ItemEditorWindow.self)?.finishClose()
  return 0
}
