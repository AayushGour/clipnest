// SettingsWindow+Shortcuts.swift
//
// P7-D (Linux port, GTK4 view layer): the Shortcuts settings tab —
// read-only (see `LinuxShortcutDescriptions.swift`'s doc comment for why
// this differs from macOS's rebindable `ShortcutsSettingsView`). Touches no
// `SettingsStore` state at all, so — unlike every other tab in this
// window — nothing here needs `@MainActor`/`MainActor.assumeIsolated`.
import CGtk4

extension SettingsWindow {
  func buildShortcutsTab() {
    let box = appendTab(title: "Shortcuts")

    let note: OpaquePointer = gtk_label_new("These shortcuts work while the picker is open.")
    gtk_label_set_xalign(note, 0)
    gtk_widget_add_css_class(note, "dim-label")
    gtk_box_append(box, note)

    for entry in LinuxShortcutDescriptions.all {
      let row: OpaquePointer = gtk_box_new(
        GTK_ORIENTATION_HORIZONTAL, SettingsWindow.controlSpacing)
      let comboLabel: OpaquePointer = gtk_label_new(entry.combo)
      gtk_label_set_xalign(comboLabel, 0)
      gtk_widget_set_size_request(row, -1, -1)
      gtk_widget_add_css_class(comboLabel, "dim-label")
      gtk_box_append(row, comboLabel)
      let descriptionLabel: OpaquePointer = gtk_label_new(entry.description)
      gtk_label_set_xalign(descriptionLabel, 0)
      gtk_box_append(row, descriptionLabel)
      gtk_box_append(box, row)
    }
  }
}
