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
    dispatch(action)
    return 1
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
      onDismiss()
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
    onDismiss()
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
