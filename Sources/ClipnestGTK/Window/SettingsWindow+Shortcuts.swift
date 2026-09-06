// SettingsWindow+Shortcuts.swift
//
// P7-D (Linux port, GTK4 view layer): the Shortcuts settings tab.
//
// T-OPT2 fix: this tab used to be a fully read-only reference list, and
// never showed the global toggle-picker hotkey at all — a user could
// neither discover nor change the single most important shortcut in the
// product. It now has two sections:
//
//  1. The GLOBAL toggle-picker shortcut — shown with its CURRENT value
//     (`GlobalHotkeyAccelerator.current()`, read straight from the shared
//     `app.clipnest.Clipnest.Keybindings` GSettings schema, never a
//     hardcoded string) and a "Record New Shortcut…" button that captures
//     the next valid key combination via a `GtkEventControllerKey`
//     (`GlobalHotkeyRecorder` below), validates it
//     (`Support/GlobalHotkeyAcceleratorValidation.swift`), persists it
//     (`Hotkeys/GlobalHotkeyAccelerator.swift`), and re-installs the
//     GSettings custom-keybinding floor so the new chord works even without
//     the GNOME Shell extension (`reinstallToggleHotkeyFloor`, injected from
//     `ClipnestLinuxAppKit` — see that property's doc comment on
//     `SettingsWindow` for why this one crosses the module boundary as a
//     closure while the read/validate/persist steps above do not).
//  2. The eight in-picker chords (Up/Down, Enter, Ctrl+F, ...) — still a
//     read-only reference list, UNCHANGED from before this task.
//     `ShortcutsSettingsView.swift` (macOS) has no equivalent list at all
//     (only its two `KeyboardShortcuts.Recorder`s for the GLOBAL hotkeys,
//     confirmed by reading that file — verifying this task's own
//     assumption rather than trusting it) — those in-picker chords aren't
//     rebindable on macOS either, so parity requires no change here.
//
// Unlike every other tab in this window, most of this file still touches no
// `SettingsStore` state (`LinuxShortcutDescriptions.swift`'s doc comment
// explains why the in-picker half is separate/display-only) — but IS now
// `@MainActor`, matching every other tab builder, since `GlobalHotkeyAccelerator
// .current()`/`.write(_:)` run real GSettings I/O on the same GTK/main thread
// as every other control here (see `SettingsWindow.swift`'s top doc comment
// for why that's the correct isolation for this whole window).
import CGtk4

extension SettingsWindow {
  @MainActor
  func buildShortcutsTab() {
    let box = appendTab(title: "Shortcuts")

    let row: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, SettingsWindow.controlSpacing)
    let openLabel: OpaquePointer = gtk_label_new("Open Clipnest (global shortcut)")
    gtk_label_set_xalign(openLabel, 0)
    gtk_widget_set_hexpand(openLabel, 1)
    gtk_box_append(row, openLabel)

    let valueLabel: OpaquePointer = gtk_label_new(GlobalHotkeyRecorder.currentDisplayValue())
    gtk_widget_add_css_class(valueLabel, "dim-label")
    gtk_box_append(row, valueLabel)
    gtk_box_append(box, row)

    let recordButton: OpaquePointer = gtk_button_new_with_label("Record New Shortcut…")
    gtk_box_append(box, recordButton)

    let errorLabel = addErrorLabel(to: box)
    let statusLabel = addStatusLabel(to: box)
    // Found via runtime screenshot verification (Docker VNC container):
    // neither `addErrorLabel`/`addStatusLabel` wrap their text (every OTHER
    // caller's messages are short enough that it never showed), and this
    // tab's own copy is long enough that an unwrapped `GtkLabel` forces the
    // whole Settings window to grow to fit one line — stretching it from
    // its normal ~480px to over 1000px. Wrapping just these two labels
    // (not `SettingsWindow+Controls.swift`'s shared builder, which isn't
    // this task's owned-files scope) fixes it without touching any other
    // tab's behavior.
    for label in [errorLabel, statusLabel] {
      gtk_label_set_wrap(label, 1)
      gtk_label_set_max_width_chars(label, 46)
    }

    // `GlobalHotkeyRecorder` is never stored on `self` — see its own doc
    // comment: it lives entirely as `gtkConnect`'s retained `user_data` for
    // the two connections made below, which (like every control in this
    // permanent, app-lifetime window) are never disconnected.
    let recorder = GlobalHotkeyRecorder(
      valueLabel: valueLabel, errorLabel: errorLabel, statusLabel: statusLabel,
      reinstallFloor: reinstallToggleHotkeyFloor)

    gtkConnect(
      recordButton, signal: "clicked", context: recorder,
      callback: unsafeBitCast(shortcutsRecorderButtonClickedTrampoline, to: GCallback.self))

    // Attached to the top-level WINDOW (not the button), `GTK_PHASE_CAPTURE`
    // — mirrors `PickerWindow+Keyboard.swift`'s identical reasoning: this
    // must see every key press before whatever widget currently has focus,
    // regardless of which one that is, so recording works no matter where
    // focus happens to be when "Record New Shortcut…" is clicked. Gated
    // entirely on `GlobalHotkeyRecorder.isRecording` internally, so it is a
    // complete no-op (returns `GDK_EVENT_PROPAGATE`) for every key press
    // outside an active recording session — every other control in this
    // window (Tab navigation, mnemonics, the notebook's own tab switching,
    // closing the window) is unaffected.
    let keyController: OpaquePointer = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(keyController, GTK_PHASE_CAPTURE)
    gtkConnect(
      keyController, signal: "key-pressed", context: recorder,
      callback: unsafeBitCast(shortcutsRecorderKeyPressedTrampoline, to: GCallback.self))
    gtk_widget_add_controller(window, keyController)

    let note: OpaquePointer = gtk_label_new("These shortcuts work while the picker is open.")
    gtk_label_set_xalign(note, 0)
    gtk_widget_add_css_class(note, "dim-label")
    gtk_box_append(box, note)

    for entry in LinuxShortcutDescriptions.all {
      let entryRow: OpaquePointer = gtk_box_new(
        GTK_ORIENTATION_HORIZONTAL, SettingsWindow.controlSpacing)
      let comboLabel: OpaquePointer = gtk_label_new(entry.combo)
      gtk_label_set_xalign(comboLabel, 0)
      gtk_widget_set_size_request(entryRow, -1, -1)
      gtk_widget_add_css_class(comboLabel, "dim-label")
      gtk_box_append(entryRow, comboLabel)
      let descriptionLabel: OpaquePointer = gtk_label_new(entry.description)
      gtk_label_set_xalign(descriptionLabel, 0)
      gtk_box_append(entryRow, descriptionLabel)
      gtk_box_append(box, entryRow)
    }
  }
}

/// Owns the "record a new global toggle accelerator" flow end to end:
/// capture (via the caller-attached `GtkEventControllerKey`), validate
/// (`GlobalHotkeyAcceleratorValidation`), persist
/// (`GlobalHotkeyAccelerator`), and re-install the GSettings floor
/// (`reinstallFloor`, `ClipnestLinuxAppKit.ToggleHotkeyFloorBinding` on the
/// other side of that closure). Deliberately NOT an extension of
/// `SettingsWindow` (a Swift extension cannot add stored properties, and
/// this needs several: `isRecording` plus four widget handles) — see
/// `buildShortcutsTab()`'s call site for why it never needs to be stored on
/// `SettingsWindow` either.
private final class GlobalHotkeyRecorder {
  private let valueLabel: OpaquePointer
  private let errorLabel: OpaquePointer
  private let statusLabel: OpaquePointer
  private let reinstallFloor: (String) -> Void
  private var isRecording = false

  init(
    valueLabel: OpaquePointer, errorLabel: OpaquePointer, statusLabel: OpaquePointer,
    reinstallFloor: @escaping (String) -> Void
  ) {
    self.valueLabel = valueLabel
    self.errorLabel = errorLabel
    self.statusLabel = statusLabel
    self.reinstallFloor = reinstallFloor
  }

  /// The GLOBAL toggle-picker accelerator's initial display value, read at
  /// tab-build time — a `static` so `buildShortcutsTab()` can seed
  /// `valueLabel`'s initial text before a `GlobalHotkeyRecorder` instance
  /// (which owns updating that SAME label on every later successful
  /// rebind) even exists yet.
  static func currentDisplayValue() -> String {
    guard let accelerator = GlobalHotkeyAccelerator.current() else { return "Not set" }
    return GlobalHotkeyAcceleratorValidation.displayLabel(for: accelerator) ?? accelerator
  }

  /// `GtkButton::clicked` on "Record New Shortcut…" — a plain toggle:
  /// click once to start recording, click again to cancel (mirrors pressing
  /// Escape mid-recording, see `handleKeyPressed` below).
  func handleRecordButtonClicked() {
    if isRecording {
      cancelRecording()
    } else {
      beginRecording()
    }
  }

  private func beginRecording() {
    isRecording = true
    setLabel(errorLabel, text: nil)
    setLabel(statusLabel, text: "Press the new key combination… (Esc to cancel)")
  }

  private func cancelRecording() {
    isRecording = false
    setLabel(statusLabel, text: nil)
    // Found via runtime screenshot verification (Docker VNC container, this
    // task's mandated check): a rejected attempt's inline error must not
    // linger after the user cancels out of recording entirely (Escape) —
    // otherwise a stale "no modifier key" error stays visible next to an
    // otherwise-normal, non-recording button.
    setLabel(errorLabel, text: nil)
  }

  /// `GtkEventControllerKey::key-pressed` — returns `1` (`GDK_EVENT_STOP`,
  /// consuming the key press) whenever a recording session is active,
  /// `0` (`GDK_EVENT_PROPAGATE`) otherwise, so this controller is invisible
  /// to the rest of the window except during an active recording.
  func handleKeyPressed(keyval: UInt32, state: UInt32) -> Int32 {
    guard isRecording else { return 0 }
    // GDK_KEY_Escape — the same public, ABI-stable X11/GDK keysym value
    // `KeyEventMapping.swift`'s own `Keyval.escape` uses (see that file's
    // top doc comment for why these are hardcoded numeric constants here
    // rather than an imported enum case name).
    let escapeKeyval: UInt32 = 0xff1b
    guard keyval != escapeKeyval else {
      cancelRecording()
      return 1
    }
    switch GlobalHotkeyAcceleratorValidation.validate(keyval: keyval, state: state) {
    case .success(let accelerator):
      commit(accelerator)
    case .failure(let failure):
      // Stay in recording mode — the task's own requirement is a clear
      // inline error, not silently doing nothing and not exiting recording
      // over a single rejected key press (e.g. a stray, still-held
      // modifier key firing its own "key-pressed" before the user's real
      // combination completes).
      setLabel(errorLabel, text: message(for: failure))
    }
    return 1
  }

  private func commit(_ accelerator: String) {
    isRecording = false
    setLabel(statusLabel, text: nil)
    guard GlobalHotkeyAccelerator.write(accelerator) else {
      setLabel(
        errorLabel,
        text:
          "Could not save the new shortcut — the app.clipnest.Clipnest.Keybindings GSettings schema isn't installed."
      )
      return
    }
    setLabel(errorLabel, text: nil)
    gtk_label_set_text(
      valueLabel, GlobalHotkeyAcceleratorValidation.displayLabel(for: accelerator) ?? accelerator)
    reinstallFloor(accelerator)
    setLabel(
      statusLabel,
      text:
        "Saved. The GNOME Shell extension picks this up immediately; without it (or if it's later disabled), you may need to log out and back in for the new shortcut to take effect."
    )
  }

  private func message(for failure: GlobalHotkeyAcceleratorValidation.Failure) -> String {
    switch failure {
    case .empty:
      return "No key was captured — try again."
    case .noModifier:
      return "A global shortcut needs at least one modifier key (Ctrl, Alt, Shift, or Super)."
    case .notAnAccelerator:
      return "That key combination can't be used as a shortcut — try another."
    }
  }

  /// Mirrors `SettingsWindow.setStatusLabel(_:text:)`'s exact two-line body
  /// (hidden + empty when `text == nil`, visible with `text` otherwise) —
  /// duplicated rather than called because `GlobalHotkeyRecorder` is
  /// deliberately not an extension of `SettingsWindow` (see this class's
  /// top doc comment); `errorLabel`/`statusLabel` are themselves already
  /// built by `SettingsWindow.addErrorLabel`/`addStatusLabel`; only this
  /// small setter needs its own copy.
  private func setLabel(_ label: OpaquePointer, text: String?) {
    gtk_widget_set_visible(label, text == nil ? 0 : 1)
    gtk_label_set_text(label, text ?? "")
  }
}

/// `GtkButton::clicked` — `void (*)(GtkButton*, gpointer)`. A small,
/// file-local duplicate of `SettingsWindow+Controls.swift`'s
/// `buttonClickedTrampoline` (that one is `private` to its own file, hence
/// unreachable here) — identical shape, but this tab's click handler needs
/// `GlobalHotkeyRecorder`'s own method directly rather than a generic
/// `ClosureContext<Void>`.
private let shortcutsRecorderButtonClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    guard let recorder = unretainedContext(data, as: GlobalHotkeyRecorder.self) else { return }
    recorder.handleRecordButtonClicked()
  }

/// `GtkEventControllerKey::key-pressed` — `gboolean (*)(GtkEventControllerKey*,
/// guint keyval, guint keycode, GdkModifierType state, gpointer)`. Same
/// signature as `PickerWindow+Keyboard.swift`'s `keyPressedTrampoline`
/// (that one is `private` to its own file too) — see
/// `Interop/GTKCallbackTrampoline.swift`'s top doc comment for why every
/// parameter here is a plain ABI-compatible Swift type rather than an
/// imported enum name.
private let shortcutsRecorderKeyPressedTrampoline:
  @convention(c) (
    OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?
  ) -> Int32 = { _, keyval, _, state, data in
    guard let recorder = unretainedContext(data, as: GlobalHotkeyRecorder.self) else { return 0 }
    return recorder.handleKeyPressed(keyval: keyval, state: state)
  }
