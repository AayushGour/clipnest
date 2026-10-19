// GTKShimsForWelcome.swift
//
// T-WELCOME1-LX: the extra GTK entry points the welcome window needs, shimmed
// exactly like `Interop/GTKShims.swift` (same-named overloads taking
// `OpaquePointer`, so the window code reads as if the C API did). Kept in its
// own file, like `GTKShimsForRowActionsAndEditor.swift`, rather than growing
// the shared shim file.
import CGtk4

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_frame_new() -> OpaquePointer {
  OpaquePointer(gtk_frame_new(nil)!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_frame_set_child(_ frame: OpaquePointer, _ child: OpaquePointer) {
  gtk_frame_set_child(
    gtkPointer(frame) as UnsafeMutablePointer<GtkFrame>,
    gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_set_default_widget(_ window: OpaquePointer, _ widget: OpaquePointer) {
  gtk_window_set_default_widget(
    gtkPointer(window) as UnsafeMutablePointer<GtkWindow>,
    gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_set_focus(_ window: OpaquePointer, _ widget: OpaquePointer) {
  gtk_window_set_focus(
    gtkPointer(window) as UnsafeMutablePointer<GtkWindow>,
    gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_remove_css_class(_ widget: OpaquePointer, _ cssClass: String) {
  gtk_widget_remove_css_class(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, cssClass)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_box_remove(_ box: OpaquePointer, _ child: OpaquePointer) {
  gtk_box_remove(
    gtkPointer(box) as UnsafeMutablePointer<GtkBox>,
    gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_get_next_sibling(_ widget: OpaquePointer) -> OpaquePointer? {
  gtk_widget_get_next_sibling(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>).map(
    OpaquePointer.init)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_box_insert_child_after(
  _ box: OpaquePointer, _ child: OpaquePointer, _ sibling: OpaquePointer
) {
  gtk_box_insert_child_after(
    gtkPointer(box) as UnsafeMutablePointer<GtkBox>,
    gtkPointer(child) as UnsafeMutablePointer<GtkWidget>,
    gtkPointer(sibling) as UnsafeMutablePointer<GtkWidget>)
}
