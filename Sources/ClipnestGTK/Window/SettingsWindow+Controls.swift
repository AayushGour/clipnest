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
