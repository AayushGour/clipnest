// PickerWindow+Keyboard.swift
//
// P7-D (Linux port, GTK4 view layer): `connectSignals()` — the aggregator
// called once from `PickerWindow.init`, right after `buildLayout()` — plus
// the keyboard shortcut controller, the search entry's live-filter signal,
// and dismiss-on-focus-loss. `KeyEventMapping.action(keyval:state:)`
// (`Support/`) is the single source of truth for what a key press MEANS;
// this file only dispatches the resulting `PickerKeyAction` to the right
// `PickerViewModel`/GTK call.
//
// The key controller is attached to the WINDOW (not the search entry) with
// `GTK_PHASE_CAPTURE`, so it sees every key press BEFORE the focused
// widget's own default handling — otherwise a `GtkSearchEntry`'s internal
// Return/Escape bindings could consume the event before this picker's own
// shortcuts ever ran. Returning `1` (`GDK_EVENT_STOP`) only for keys
// `KeyEventMapping` actually binds lets every other key (ordinary typing)
// fall through to the search entry untouched.
import CGtk4
import ClipnestViewModels

extension PickerWindow {
  func connectSignals() {
    connectRowSignals()
    connectKeyController()
    connectSearchEntry()
    connectWindowActivation()
    connectPreviewMotion()
    // Linux parity pass (routed follow-up, 2026-09-06): the row right-click
    // context menu — see `PickerWindow+ContextMenu.swift`.
    connectContextMenuGesture()
  }

  private func connectKeyController() {
    let controller: OpaquePointer = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
    gtkConnect(
      controller, signal: "key-pressed", context: self,
      callback: unsafeBitCast(keyPressedTrampoline, to: GCallback.self))
    gtk_widget_add_controller(window, controller)
  }

  private func connectSearchEntry() {
    gtkConnect(
      searchEntry, signal: "search-changed", context: self,
      callback: unsafeBitCast(searchChangedTrampoline, to: GCallback.self))
  }

  /// `notify::is-active` — fires whenever this window's own active/focused
  /// state changes; used to implement "onDismiss fires ... when the window
  /// loses focus" (this task's API contract). `isAwaitingInitialActivation`
  /// (set in `show(at:)`) skips the very first observed transition so
  /// presenting the window doesn't immediately fire a spurious dismiss
  /// before it has ever actually been active.
  private func connectWindowActivation() {
    gtkConnect(
      window, signal: "notify::is-active", context: self,
      callback: unsafeBitCast(windowActiveChangedTrampoline, to: GCallback.self))
  }

  func handleKeyPressed(keyval: UInt32, state: UInt32) -> Int32 {
    guard let action = KeyEventMapping.action(keyval: keyval, state: state) else { return 0 }
    // P0 DATA LOSS, found by black-box testing on Ubuntu 22.04 and confirmed on
    // a clean HEAD build: typing in the search field and pressing Delete
    // permanently destroyed the highlighted clipboard item (measured: 4 rows ->
    // 3, no confirmation, no undo).
    //
    // This controller is attached at GTK_PHASE_CAPTURE, so it sees every key
    // BEFORE the focused widget does. That is required for the picker's own
    // chords (arrows, Ctrl-chords, Escape) to work while the search entry holds
    // focus, which it does for most of the picker's life. Bare Delete was
    // harmless under that arrangement only while it required Ctrl; making it
    // bare to match macOS (T-KBPARITY1) turned it into a key the text field
    // legitimately owns.
    //
    // macOS does not have this problem because SwiftUI routes the keystroke to
    // the focused control first; GTK's capture phase deliberately does the
    // opposite. So the fix belongs here, not in `KeyEventMapping` (which stays
    // a pure keyval->action mapping with no view state) — see that type's own
    // doc comment.
    if action.isTextEditingKeyWhenTypingInSearch, isTypingInSearchField {
      return 0  // GDK_EVENT_PROPAGATE — let the focused GtkEntry handle it
    }
    dispatch(action)
    return 1
  }

  /// Whether the user is actively editing search text, so a text-editing key
  /// belongs to the entry rather than to the picker.
  ///
  /// Requires BOTH focus and non-empty text, and the second half is not
  /// redundant: `willShow()` focuses the search entry every time the picker
  /// opens, so a focus-only check would mean bare Delete never reached the list
  /// at all — measured, after a first attempt at this fix did exactly that.
  ///
  /// With an empty search box there is nothing for Delete to edit, so the
  /// picker's own meaning (delete the highlighted item) is the only sensible
  /// one; once the user has typed something, Delete is forward-delete and the
  /// entry owns it. That split matches what a user intends in each state and
  /// keeps macOS parity for the common case of opening the picker and pressing
  /// Delete straight away.
  private var isTypingInSearchField: Bool {
    guard gtkFocusIsWithin(window: window, widget: searchEntry) else { return false }
    return !String(cString: gtk_editable_get_text(searchEntry)).isEmpty
  }

  /// Dispatches one mapped `PickerKeyAction` — see `PickerKeyAction.swift`'s
  /// doc comment for why this enum, not a raw keyval, is what every caller
  /// switches over.
  private func dispatch(_ action: PickerKeyAction) {
    switch action {
    case .moveUp:
      MainActor.assumeIsolated { viewModel.moveSelection(by: -1) }
    case .moveDown:
      MainActor.assumeIsolated { viewModel.moveSelection(by: 1) }
    case .commit(let plainText):
      MainActor.assumeIsolated { viewModel.selectHighlighted(plainText: plainText) }
    case .dismiss:
      dismiss()
    case .focusSearch:
      gtk_widget_grab_focus(searchEntry)
    case .togglePin:
      MainActor.assumeIsolated { viewModel.togglePinHighlighted() }
    case .delete:
      MainActor.assumeIsolated { viewModel.deleteHighlighted() }
    case .switchTab(let index):
      guard tabButtons.indices.contains(index.rawValue - 1) else { return }
      gtk_toggle_button_set_active(tabButtons[index.rawValue - 1], 1)
    }
  }

  func handleSearchChanged() {
    let text = String(cString: gtk_editable_get_text(searchEntry))
    MainActor.assumeIsolated {
      viewModel.searchTextChanged(text)
    }
  }

  func handleWindowActiveChanged() {
    guard gtk_window_is_active(window) == 0 else {
      isAwaitingInitialActivation = false
      return
    }
    guard !isAwaitingInitialActivation else { return }
    // Linux parity pass (routed follow-up, 2026-09-06), real bug found by
    // this task's own runtime verification: see `isContextMenuOpen`'s doc
    // comment (`PickerWindow.swift`) — the right-click context menu's
    // implicit autohide grab fires this exact `notify::is-active`
    // transition, indistinguishable here from a genuine focus loss to a
    // different application, without this guard.
    guard !isContextMenuOpen else { return }
    // Linux parity pass (routed follow-up, 2026-09-06), a second real bug
    // in the same family: see `isEditorSessionActive`'s doc comment
    // (`PickerWindow.swift`) — presenting `SnippetEditorWindow` also fires
    // this exact transition (window-manager focus genuinely moves to that
    // window), which used to fully dismiss the picker instead of just
    // losing window-manager prominence, unlike macOS's side-by-side
    // non-dismissing design.
    guard !isEditorSessionActive else { return }
    dismiss()
  }
}

/// `GtkEventControllerKey::key-pressed` — `gboolean (*)(GtkEventControllerKey*,
/// guint keyval, guint keycode, GdkModifierType state, gpointer)`.
private let keyPressedTrampoline:
  @convention(c) (
    OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?
  ) -> Int32 = { _, keyval, _, state, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return 0 }
    return window.handleKeyPressed(keyval: keyval, state: state)
  }

/// `GtkSearchEntry::search-changed` — `void (*)(GtkSearchEntry*, gpointer)`.
private let searchChangedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
      window.handleSearchChanged()
    }

/// `notify::is-active` — GObject's generic `notify` signal:
/// `void (*)(GObject*, GParamSpec*, gpointer)`.
private let windowActiveChangedTrampoline:
  @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { _, _, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handleWindowActiveChanged()
  }
