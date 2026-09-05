// PickerWindow+Layout.swift
//
// P7-D (Linux port, GTK4 view layer): widget-tree construction, called once
// from `PickerWindow.init`. Pure GTK-widget wiring — no `PickerViewModel`
// reads/writes here (those happen once `connectSignals()`, `PickerWindow
// +Rows.swift`'s rebuild functions, and the poll loop run) — kept separate
// from `connectSignals()` (`PickerWindow+Keyboard.swift`/`+Rows.swift`/
// `+Chips.swift`/`+Preview.swift`) so this file answers only "what does the
// window look like," not "what does it do."
//
// Tree:
//   window
//     └─ outerBox (vertical)
//          ├─ searchEntry
//          ├─ chipsBox (horizontal — type-filter chips)
//          ├─ tabsBox (horizontal — History/Pinned/Snippets)
//          ├─ scrolledWindow
//          │    └─ listBox
//          ├─ loadingLabel               (shown instead of scrolledWindow
//          │                              while `isSearching` — see
//          │                              PickerWindow+Polling.swift)
//          └─ footerLabel                (ShortcutHints text)
//   previewPopover (parented to listBox, NOT part of the tree above —
//                    GtkPopover manages its own floating surface)
//        └─ previewBox (vertical)
//             ├─ previewImage
//             └─ previewLabel
import CGtk4

extension PickerWindow {
  static let outerSpacing: Int32 = 8
  static let chipSpacing: Int32 = 4
  static let outerMargin: Int32 = 8

  func buildLayout() {
    let outerBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.outerSpacing)
    gtk_widget_set_margin_start(outerBox, PickerWindow.outerMargin)
    gtk_widget_set_margin_end(outerBox, PickerWindow.outerMargin)
    gtk_widget_set_margin_top(outerBox, PickerWindow.outerMargin)
    gtk_widget_set_margin_bottom(outerBox, PickerWindow.outerMargin)

    gtk_box_append(outerBox, searchEntry)
    gtk_box_append(outerBox, chipsBox)
    gtk_box_append(outerBox, tabsBox)

    gtk_scrolled_window_set_policy(scrolledWindow, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_widget_set_vexpand(scrolledWindow, 1)
    gtk_list_box_set_selection_mode(listBox, GTK_SELECTION_SINGLE)
    gtk_scrolled_window_set_child(scrolledWindow, listBox)
    gtk_box_append(outerBox, scrolledWindow)

    gtk_widget_set_halign(loadingLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(loadingLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(loadingLabel, 1)
    gtk_widget_set_visible(loadingLabel, 0)
    gtk_box_append(outerBox, loadingLabel)

    gtk_label_set_xalign(footerLabel, 0)
    gtk_widget_add_css_class(footerLabel, "dim-label")
    gtk_box_append(outerBox, footerLabel)

    gtk_window_set_child(window, outerBox)

    buildTabs()
    buildChips()
    buildPreviewPopover()
  }

  /// The hover-preview popover's content — built once and reused for every
  /// row (see `PickerWindow+Preview.swift`, which only ever mutates this
  /// content's visibility/markup/pixbuf, never rebuilds it).
  func buildPreviewPopover() {
    gtk_widget_set_parent(previewPopover, listBox)
    gtk_popover_set_autohide(previewPopover, 0)

    let previewBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.outerSpacing)
    gtk_widget_set_size_request(previewImage, ThumbnailBounds.previewMaxPixelSize.gtkInt32, -1)
    gtk_box_append(previewBox, previewImage)
    gtk_label_set_wrap(previewLabel, 1)
    gtk_box_append(previewBox, previewLabel)
    gtk_popover_set_child(previewPopover, previewBox)
  }
}
