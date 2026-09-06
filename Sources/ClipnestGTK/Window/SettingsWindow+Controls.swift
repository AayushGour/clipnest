// SettingsWindow+Controls.swift
//
// P7-D (Linux port, GTK4 view layer): small, reusable control builders
// shared by every `SettingsWindow+*.swift` tab file — a checkbox, a
// radio-style group of checkbuttons (`gtk_check_button_set_group` is
// GTK4's replacement for the removed `GtkRadioButton`), and a labeled spin
// button. Each wires straight to a `SettingsStore` write via the caller's
// closure, using `Interop/GTKCallbackTrampoline.swift`'s generic
// `ClosureContext<Value>` — no bespoke context type per control.
import CGtk4

extension SettingsWindow {
  @discardableResult
  func addCheckButton(
    to box: OpaquePointer, label: String, initialValue: Bool,
    onToggled: @escaping (Bool) -> Void
  ) -> OpaquePointer {
    let button: OpaquePointer = gtk_check_button_new_with_label(label)
    gtk_check_button_set_active(button, initialValue ? 1 : 0)
    gtkConnect(
      button, signal: "toggled", context: ClosureContext(onToggled),
      callback: unsafeBitCast(checkButtonToggledTrampoline, to: GCallback.self))
    gtk_box_append(box, button)
    return button
  }

  /// A mutually-exclusive group of checkbuttons (radio-style) — `options`
  /// is index-aligned with the callback's `selectedIndex`.
  @discardableResult
  func addRadioGroup(
    to box: OpaquePointer, options: [(label: String, isInitiallyActive: Bool)],
    onSelected: @escaping (_ selectedIndex: Int) -> Void
  ) -> [OpaquePointer] {
    var buttons: [OpaquePointer] = []
    var groupSource: OpaquePointer?
    for (index, option) in options.enumerated() {
      let button: OpaquePointer = gtk_check_button_new_with_label(option.label)
      if let groupSource {
        gtk_check_button_set_group(button, groupSource)
      } else {
        groupSource = button
      }
      gtk_check_button_set_active(button, option.isInitiallyActive ? 1 : 0)
      // A group's "toggled" fires for BOTH the newly-active button and
      // whichever one just turned off — only act on the `true` case,
      // mirroring `PickerWindow+Chips.swift`'s identical guard.
      gtkConnect(
        button, signal: "toggled",
        context: ClosureContext<Bool> { isActive in
          guard isActive else { return }
          onSelected(index)
        },
        callback: unsafeBitCast(checkButtonToggledTrampoline, to: GCallback.self))
      gtk_box_append(box, button)
      buttons.append(button)
    }
    return buttons
  }

  @discardableResult
  func addButton(to box: OpaquePointer, label: String, onClicked: @escaping () -> Void)
    -> OpaquePointer
  {
    let button: OpaquePointer = gtk_button_new_with_label(label)
    gtkConnect(
      button, signal: "clicked", context: ClosureContext<Void> { onClicked() },
      callback: unsafeBitCast(buttonClickedTrampoline, to: GCallback.self))
    gtk_box_append(box, button)
    return button
  }

  @discardableResult
  func addSpinButton(
    to box: OpaquePointer, label: String, min: Double, max: Double, step: Double,
    initialValue: Double, onChanged: @escaping (Int) -> Void
  ) -> OpaquePointer {
    let row: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, SettingsWindow.controlSpacing)
    let rowLabel: OpaquePointer = gtk_label_new(label)
    gtk_box_append(row, rowLabel)
    let spin: OpaquePointer = gtk_spin_button_new_with_range(min, max, step)
    gtk_spin_button_set_value(spin, initialValue)
    gtk_widget_set_hexpand(spin, 1)
    gtkConnect(
      spin, signal: "value-changed",
      context: ClosureContext<Int32> { onChanged(Int($0)) },
      callback: unsafeBitCast(spinButtonChangedTrampoline, to: GCallback.self))
    gtk_box_append(row, spin)
    gtk_box_append(box, row)
    return spin
  }

  /// A `dim-label`-styled status/progress line — used for every inline
  /// status text this window shows (the OCR backfill row's progress/
  /// pending/summary text). Hidden by default: `setStatusLabel(_:text:)`
  /// below is the only intended way to reveal it, so "no message" never
  /// renders as a blank line.
  @discardableResult
  func addStatusLabel(to box: OpaquePointer) -> OpaquePointer {
    let label: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(label, 0)
    gtk_widget_add_css_class(label, "dim-label")
    gtk_widget_set_visible(label, 0)
    gtk_box_append(box, label)
    return label
  }

  /// A red-styled status/error line — the GTK counterpart of macOS's
  /// `Text(...).foregroundStyle(.red)` inline error rows (launch-at-login,
  /// Clear All History). Hidden by default, same contract as
  /// `addStatusLabel(to:)`.
  @discardableResult
  func addErrorLabel(to box: OpaquePointer) -> OpaquePointer {
    let label: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_xalign(label, 0)
    gtk_widget_add_css_class(label, "error")
    gtk_widget_set_visible(label, 0)
    gtk_box_append(box, label)
    return label
  }

  /// Sets `label`'s text and visibility together — `text == nil` hides it
  /// (clearing any previously-shown message) rather than showing an empty
  /// line; every caller of `addStatusLabel`/`addErrorLabel` above updates
  /// through this, never `gtk_label_set_text`/`gtk_widget_set_visible`
  /// directly, so the two can never drift out of sync.
  func setStatusLabel(_ label: OpaquePointer, text: String?) {
    gtk_widget_set_visible(label, text == nil ? 0 : 1)
    gtk_label_set_text(label, text ?? "")
  }

  /// A `GtkProgressBar` — used only by the OCR backfill row today.
  @discardableResult
  func addProgressBar(to box: OpaquePointer) -> OpaquePointer {
    let progressBar: OpaquePointer = gtk_progress_bar_new()
    gtk_widget_set_visible(progressBar, 0)
    gtk_box_append(box, progressBar)
    return progressBar
  }

  /// GTK's own ABI-stable response IDs (`gtk/gtkdialog.h`), used directly
  /// as `Int32` rather than via the imported `GtkResponseType` — whose
  /// exact Swift-import shape (bare `Int32` vs. a `RawRepresentable`
  /// wrapper struct) is unverified for this GTK build (unlike the small set
  /// of types `Interop/GTKShims.swift`'s top doc comment already verified
  /// empirically) and irrelevant either way: these two numeric values never
  /// change — they are part of GTK's public, frozen ABI.
  private enum DialogResponse {
    static let cancel: Int32 = -6  // GTK_RESPONSE_CANCEL
    static let accept: Int32 = -3  // GTK_RESPONSE_ACCEPT
  }

  /// Shows a modal confirmation dialog (a plain `GtkDialog`, not
  /// `GtkMessageDialog` — see `gtk_dialog_new()`'s call site below) with
  /// `message`, a `Cancel` button, and a destructive `confirmLabel` button
  /// — the GTK counterpart of SwiftUI's `.confirmationDialog(...)` (see
  /// `HistorySettingsView.swift`'s "Clear All History…" dialog on macOS).
  /// `onConfirm` runs only for the destructive button; Cancel, Esc, or the
  /// dialog's own close button are all a no-op. The dialog destroys itself
  /// after any response — callers never hold a reference to it.
  func showConfirmationDialog(
    title: String, message: String, confirmLabel: String,
    onConfirm: @escaping () -> Void
  ) {
    let dialog: OpaquePointer = gtk_dialog_new()
    gtk_window_set_title(dialog, title)
    gtk_window_set_transient_for(dialog, window)
    gtk_window_set_modal(dialog, 1)

    let messageLabel: OpaquePointer = gtk_label_new(message)
    gtk_label_set_wrap(messageLabel, 1)
    gtk_widget_set_margin_start(messageLabel, SettingsWindow.tabMargin)
    gtk_widget_set_margin_end(messageLabel, SettingsWindow.tabMargin)
    gtk_widget_set_margin_top(messageLabel, SettingsWindow.tabMargin)
    gtk_widget_set_margin_bottom(messageLabel, SettingsWindow.tabMargin)
    gtk_box_append(gtk_dialog_get_content_area(dialog), messageLabel)

    gtk_dialog_add_button(dialog, "Cancel", DialogResponse.cancel)
    gtk_dialog_add_button(dialog, confirmLabel, DialogResponse.accept)
    gtkConnect(
      dialog, signal: "response",
      context: ClosureContext<Int32> { responseID in
        if responseID == DialogResponse.accept {
          onConfirm()
        }
      },
      callback: unsafeBitCast(dialogResponseTrampoline, to: GCallback.self))
    gtk_window_present(dialog)
  }
}

/// Shared by every checkbox/radio-group control — `GtkCheckButton::toggled`
/// is `void (*)(GtkCheckButton*, gpointer)`.
private let checkButtonToggledTrampoline:
  @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { button, data in
    guard let button, let context = unretainedContext(data, as: ClosureContext<Bool>.self) else {
      return
    }
    context.perform(gtk_check_button_get_active(button) != 0)
  }

/// `GtkButton::clicked` — `void (*)(GtkButton*, gpointer)`.
private let buttonClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let context = unretainedContext(data, as: ClosureContext<Void>.self) else { return }
      context.perform(())
    }

/// `GtkSpinButton::value-changed` — `void (*)(GtkSpinButton*, gpointer)`.
private let spinButtonChangedTrampoline:
  @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { spin, data in
    guard let spin, let context = unretainedContext(data, as: ClosureContext<Int32>.self) else {
      return
    }
    context.perform(gtk_spin_button_get_value_as_int(spin))
  }

/// `GtkDialog::response` — `void (*)(GtkDialog*, gint response_id,
/// gpointer)`. Destroys the dialog after forwarding the response, so every
/// `showConfirmationDialog(...)` caller can fire-and-forget it (see that
/// method's doc comment).
private let dialogResponseTrampoline:
  @convention(c) (
    OpaquePointer?, Int32, UnsafeMutableRawPointer?
  ) -> Void = { dialog, responseID, data in
    guard let dialog, let context = unretainedContext(data, as: ClosureContext<Int32>.self) else {
      return
    }
    context.perform(responseID)
    gtk_window_destroy(dialog)
  }

// MARK: - GTK shims not yet in `Interop/GTKShims.swift`
//
// `GtkDialog`/`GtkProgressBar` are new to this module as of P10-A
// (Settings' Clear-All-History confirmation + OCR backfill progress) —
// this task's owned-files scope is `SettingsWindow*.swift` only, not
// `Interop/GTKShims.swift`, so their shims live here instead of alongside
// that file's other empirically-verified constructors/setters. Same
// pattern as every shim there: a constructor returns a plain,
// already-unwrapped `OpaquePointer` (every GTK widget constructor's real
// return type is `GtkWidget*`, per that file's top doc comment); every
// other function takes `OpaquePointer` and casts internally via
// `gtkPointer` only where the real C signature needs a more specific
// pointer type.
//
// `gtk_message_dialog_new` (the more obvious choice for a confirmation
// dialog) turned out to be UNCALLABLE from Swift on this GTK build —
// verified directly against `swift build`'s own diagnostic: Swift's Clang
// importer marks it `@available(*, unavailable, message: "Variadic
// function is unavailable")`, since its `...` is untyped `Any...` rather
// than a `CVarArg` list the compiler can bridge. `showConfirmationDialog`
// (above) uses a plain `gtk_dialog_new()` + a manually-appended message
// label instead — every function that needs, `gtk_dialog_new`/
// `gtk_dialog_get_content_area`/`gtk_dialog_add_button`/
// `gtk_window_set_transient_for`/`gtk_window_set_modal`/
// `gtk_window_destroy`, is non-variadic and shimmed below.
//
// `GtkProgressBar` (checked the same way — a real `swift build` attempt,
// not assumed) gets NO named Swift type: `gtk_progress_bar_set_fraction`'s
// real imported signature already takes a plain `OpaquePointer!`, exactly
// like `gtk_spin_button_set_value`/`gtk_label_set_text`/every other
// no-named-type setter `Interop/GTKShims.swift`'s top doc comment
// describes — so, unlike `gtk_progress_bar_new()` below (a constructor,
// which per that same doc comment ALWAYS returns `GtkWidget*` regardless
// of the widget's own type), it needs no shim at all and is called
// directly at its one call site (`SettingsWindow+History.swift`'s
// `pollOCRBackfillTick()`).

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_dialog_new() -> OpaquePointer {
  OpaquePointer(gtk_dialog_new()!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_dialog_get_content_area(_ dialog: OpaquePointer) -> OpaquePointer {
  OpaquePointer(gtk_dialog_get_content_area(gtkPointer(dialog) as UnsafeMutablePointer<GtkDialog>)!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_dialog_add_button(_ dialog: OpaquePointer, _ buttonText: String, _ responseID: Int32) {
  _ = gtk_dialog_add_button(
    gtkPointer(dialog) as UnsafeMutablePointer<GtkDialog>, buttonText, responseID)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_set_transient_for(_ window: OpaquePointer, _ parent: OpaquePointer) {
  gtk_window_set_transient_for(
    gtkPointer(window) as UnsafeMutablePointer<GtkWindow>,
    gtkPointer(parent) as UnsafeMutablePointer<GtkWindow>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_set_modal(_ window: OpaquePointer, _ modal: Int32) {
  gtk_window_set_modal(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>, modal)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_destroy(_ window: OpaquePointer) {
  gtk_window_destroy(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_progress_bar_new() -> OpaquePointer {
  OpaquePointer(gtk_progress_bar_new()!)
}
