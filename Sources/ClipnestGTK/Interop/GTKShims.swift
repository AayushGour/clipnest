// swift-format-ignore-file: AlwaysUseLowerCamelCase

// Every function below is deliberately named to EXACTLY match its real GTK/
// GDK C counterpart (that's the entire mechanism — see this file's doc
// comment) — `AlwaysUseLowerCamelCase` would otherwise flag every one of
// them for using C's snake_case naming.
// GTKShims.swift
//
// P7-D (Linux port, GTK4 view layer): every widget/object handle in this
// module is a plain `OpaquePointer` (see `GTKCallbackTrampoline.swift`'s
// `gtkPointer<T>(_:)` doc comment for why: GObject "subclass" pointers are
// structurally compatible prefixes of their "superclass," the same fact
// C's own `GTK_WINDOW(x)`-style cast macros rely on — none of which Clang
// imports into Swift). But the ACTUAL C functions GTK exposes vary in what
// Swift type each parameter/return value gets, verified empirically against
// this exact GTK 4.6 build (Ubuntu 22.04's `libgtk-4-dev`), NOT assumed:
//
//  - Some GObject types get their OWN named Swift type, usable as
//    `UnsafeMutablePointer<TypeName>` — confirmed for `GtkWidget`,
//    `GtkWindow`, `GtkPopover`, `GtkToggleButton`, `GtkCheckButton`,
//    `GtkBox`, `GtkAdjustment`, `GtkListBoxRow`, `GtkButton`, and
//    `GdkPixbufLoader`.
//  - Others get NO named Swift type at all (Clang couldn't/didn't
//    generate one) — every use of them, parameter or return, is a plain
//    `OpaquePointer` already. Confirmed for `GtkListBox`, `GtkLabel`,
//    `GtkScrolledWindow`, `GtkSpinButton`, `GtkImage`,
//    `GtkEventController` (and its subtypes, `GtkEventControllerKey`/
//    `GtkEventControllerMotion`), `GtkEditable`, `GtkNotebook`, and
//    `GdkPixbuf`.
//  - Every WIDGET CONSTRUCTOR (`gtk_*_new*`) returns a plain (non-IUO)
//    `UnsafeMutablePointer<GtkWidget>?`/`OpaquePointer?`, regardless of
//    which of the two groups above the widget's own type falls into — so
//    every constructor needs an explicit unwrap, never an implicit one.
//
// Rather than sprinkle a cast/unwrap at every one of this module's
// hundreds of call sites, this file defines ONE same-named Swift OVERLOAD
// per GTK/GDK/GLib function actually called anywhere in `ClipnestGTK`:
// constructors return a plain, already-unwrapped `OpaquePointer`; every
// other function takes `OpaquePointer` for each object-pointer parameter
// and forwards to the real C function, casting via `gtkPointer` ONLY for
// parameters in the first group above. Swift's overload resolution picks
// these shims automatically at every call site in this module (every
// stored widget/object handle here is an `OpaquePointer`), so every other
// file is written exactly as if the whole C API took `OpaquePointer`
// uniformly and constructors never returned an optional — the real,
// per-function nullability/specific-pointer-type quirks are isolated to
// this one file. Grouped by GTK/GDK/GLib subsystem, matching the order
// widgets are introduced across `PickerWindow`/`SettingsWindow`.
//
// The `!` in every constructor shim's body is deliberate and confined to
// this file: a `nil` return from a fresh GTK widget/controller/loader
// constructor means the process is in a state (out of memory, GTK not
// initialized) with no sane recovery — matching how this exact class of
// "this cannot fail in a running GTK app" assumption is handled by every
// other GObject-C-interop language binding, and keeping every other file
// in this module free of a force-unwrap it would otherwise need to repeat
// at each of dozens of construction sites.
import CGtk4

// MARK: - GApplication / GMainLoop (ClipnestGTKApplication.swift)
// `g_main_loop_new`/`_run`/`_quit`/`_unref` and `gtk_init` need no shim —
// no object-pointer parameter/return type this module stores through an
// `OpaquePointer`.

// MARK: - GObject / GSignal (Interop/GTKCallbackTrampoline.swift)
// `g_signal_connect_data`'s `instance` parameter is `gpointer`
// (`UnsafeMutableRawPointer`), which every typed pointer — including
// `OpaquePointer`, via `UnsafeMutableRawPointer.init(_:)` — already
// converts to explicitly at that one call site; no shim needed.

// MARK: - GLib main-loop source (PickerWindow+Polling.swift)
// `g_timeout_add_full`/`g_source_remove` take only scalar/callback/gpointer
// parameters, already compatible.

// MARK: - Constructors (every `gtk_*_new*`/`gdk_*_new*` this module calls)
func gtk_window_new() -> OpaquePointer {
  OpaquePointer(gtk_window_new()!)
}
func gtk_notebook_new() -> OpaquePointer {
  OpaquePointer(gtk_notebook_new()!)
}
func gtk_box_new(_ orientation: GtkOrientation, _ spacing: Int32) -> OpaquePointer {
  OpaquePointer(gtk_box_new(orientation, spacing)!)
}
func gtk_search_entry_new() -> OpaquePointer {
  OpaquePointer(gtk_search_entry_new()!)
}
func gtk_scrolled_window_new() -> OpaquePointer {
  OpaquePointer(gtk_scrolled_window_new()!)
}
func gtk_list_box_new() -> OpaquePointer {
  OpaquePointer(gtk_list_box_new()!)
}
func gtk_label_new(_ text: String?) -> OpaquePointer {
  OpaquePointer(gtk_label_new(text)!)
}
func gtk_popover_new() -> OpaquePointer {
  OpaquePointer(gtk_popover_new()!)
}
func gtk_image_new() -> OpaquePointer {
  OpaquePointer(gtk_image_new()!)
}
func gtk_image_new_from_icon_name(_ iconName: String) -> OpaquePointer {
  OpaquePointer(gtk_image_new_from_icon_name(iconName)!)
}
func gtk_toggle_button_new() -> OpaquePointer {
  OpaquePointer(gtk_toggle_button_new()!)
}
func gtk_toggle_button_new_with_label(_ label: String) -> OpaquePointer {
  OpaquePointer(gtk_toggle_button_new_with_label(label)!)
}
func gtk_check_button_new_with_label(_ label: String) -> OpaquePointer {
  OpaquePointer(gtk_check_button_new_with_label(label)!)
}
func gtk_button_new_with_label(_ label: String) -> OpaquePointer {
  OpaquePointer(gtk_button_new_with_label(label)!)
}
func gtk_spin_button_new_with_range(_ min: Double, _ max: Double, _ step: Double) -> OpaquePointer {
  OpaquePointer(gtk_spin_button_new_with_range(min, max, step)!)
}
func gtk_entry_new() -> OpaquePointer {
  OpaquePointer(gtk_entry_new()!)
}
// `GtkEventController`/its subtypes have no named Swift type (see this
// file's top doc comment), so these two constructors already return a
// plain `OpaquePointer?` — no `OpaquePointer(...)` wrapping needed/valid.
func gtk_event_controller_key_new() -> OpaquePointer {
  gtk_event_controller_key_new()!
}
func gtk_event_controller_motion_new() -> OpaquePointer {
  gtk_event_controller_motion_new()!
}
func gdk_pixbuf_loader_new() -> OpaquePointer {
  OpaquePointer(gdk_pixbuf_loader_new()!)
}

// MARK: - GtkWidget (a real named type — nearly every call site)
func gtk_box_append(_ box: OpaquePointer, _ child: OpaquePointer) {
  gtk_box_append(gtkPointer(box) as UnsafeMutablePointer<GtkBox>, gtkPointer(child))
}
func gtk_widget_set_margin_start(_ widget: OpaquePointer, _ margin: Int32) {
  gtk_widget_set_margin_start(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, margin)
}
func gtk_widget_set_margin_end(_ widget: OpaquePointer, _ margin: Int32) {
  gtk_widget_set_margin_end(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, margin)
}
func gtk_widget_set_margin_top(_ widget: OpaquePointer, _ margin: Int32) {
  gtk_widget_set_margin_top(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, margin)
}
func gtk_widget_set_margin_bottom(_ widget: OpaquePointer, _ margin: Int32) {
  gtk_widget_set_margin_bottom(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, margin)
}
func gtk_widget_set_visible(_ widget: OpaquePointer, _ visible: Int32) {
  gtk_widget_set_visible(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, visible)
}
func gtk_widget_set_vexpand(_ widget: OpaquePointer, _ expand: Int32) {
  gtk_widget_set_vexpand(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, expand)
}
func gtk_widget_set_hexpand(_ widget: OpaquePointer, _ expand: Int32) {
  gtk_widget_set_hexpand(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, expand)
}
func gtk_widget_set_halign(_ widget: OpaquePointer, _ align: GtkAlign) {
  gtk_widget_set_halign(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, align)
}
func gtk_widget_set_valign(_ widget: OpaquePointer, _ align: GtkAlign) {
  gtk_widget_set_valign(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, align)
}
func gtk_widget_add_css_class(_ widget: OpaquePointer, _ cssClass: String) {
  gtk_widget_add_css_class(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, cssClass)
}
func gtk_widget_set_tooltip_text(_ widget: OpaquePointer, _ text: String) {
  gtk_widget_set_tooltip_text(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, text)
}
func gtk_widget_set_size_request(_ widget: OpaquePointer, _ width: Int32, _ height: Int32) {
  gtk_widget_set_size_request(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, width, height)
}
func gtk_widget_set_parent(_ widget: OpaquePointer, _ parent: OpaquePointer) {
  gtk_widget_set_parent(
    gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>,
    gtkPointer(parent) as UnsafeMutablePointer<GtkWidget>)
}
// `GtkEventController` has no named Swift type (see this file's top doc
// comment) — its parameter stays a plain `OpaquePointer`.
func gtk_widget_add_controller(_ widget: OpaquePointer, _ controller: OpaquePointer) {
  gtk_widget_add_controller(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, controller)
}
func gtk_widget_grab_focus(_ widget: OpaquePointer) {
  _ = gtk_widget_grab_focus(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>)
}
/// Whether `widget` is, or contains, the window's current focus widget.
///
/// NOT `gtk_widget_has_focus`, which was tried first and silently failed: a
/// `GtkSearchEntry` is a composite whose focusable child is an internal
/// `GtkText`, so `has_focus` on the search entry itself is always false even
/// while the user is typing into it. Asking the window for its real focus
/// widget and walking up the parent chain is what actually answers "is the
/// user typing in the search field."
func gtkFocusIsWithin(window: OpaquePointer, widget: OpaquePointer) -> Bool {
  guard
    let focused = gtk_window_get_focus(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>)
  else { return false }
  let focusedWidget = OpaquePointer(focused)
  if focusedWidget == widget { return true }
  return gtk_widget_is_ancestor(
    gtkPointer(focusedWidget) as UnsafeMutablePointer<GtkWidget>,
    gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>) != 0
}
func gtk_widget_get_first_child(_ widget: OpaquePointer) -> OpaquePointer? {
  gtk_widget_get_first_child(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>).map(
    OpaquePointer.init)
}

// MARK: - GtkWindow (a real named type)
func gtk_window_set_title(_ window: OpaquePointer, _ title: String) {
  gtk_window_set_title(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>, title)
}
func gtk_window_set_decorated(_ window: OpaquePointer, _ decorated: Int32) {
  gtk_window_set_decorated(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>, decorated)
}
func gtk_window_set_resizable(_ window: OpaquePointer, _ resizable: Int32) {
  gtk_window_set_resizable(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>, resizable)
}
func gtk_window_set_default_size(_ window: OpaquePointer, _ width: Int32, _ height: Int32) {
  gtk_window_set_default_size(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>, width, height)
}
func gtk_window_set_hide_on_close(_ window: OpaquePointer, _ hide: Int32) {
  gtk_window_set_hide_on_close(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>, hide)
}
func gtk_window_set_child(_ window: OpaquePointer, _ child: OpaquePointer) {
  gtk_window_set_child(
    gtkPointer(window) as UnsafeMutablePointer<GtkWindow>,
    gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}
func gtk_window_present(_ window: OpaquePointer) {
  gtk_window_present(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>)
}
func gtk_window_is_active(_ window: OpaquePointer) -> Int32 {
  gtk_window_is_active(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>)
}

// MARK: - GtkScrolledWindow (NO named Swift type — plain OpaquePointer)
// `gtk_scrolled_window_set_policy` needs NO shim: every parameter (the
// `OpaquePointer` scrolled window plus two scalar `GtkPolicyType` enum
// values) already matches the real C function's imported signature
// exactly — a shim with the identical signature would just call itself
// (verified: this was an actual "infinite recursion" compiler warning
// before this comment replaced it).
func gtk_scrolled_window_set_child(_ scrolledWindow: OpaquePointer, _ child: OpaquePointer) {
  gtk_scrolled_window_set_child(
    scrolledWindow, gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}
func gtk_scrolled_window_get_vadjustment(_ scrolledWindow: OpaquePointer) -> OpaquePointer {
  OpaquePointer(gtk_scrolled_window_get_vadjustment(scrolledWindow))
}

// MARK: - GtkAdjustment (a real named type)
func gtk_adjustment_get_value(_ adjustment: OpaquePointer) -> Double {
  gtk_adjustment_get_value(gtkPointer(adjustment) as UnsafeMutablePointer<GtkAdjustment>)
}
func gtk_adjustment_get_page_size(_ adjustment: OpaquePointer) -> Double {
  gtk_adjustment_get_page_size(gtkPointer(adjustment) as UnsafeMutablePointer<GtkAdjustment>)
}
func gtk_adjustment_get_upper(_ adjustment: OpaquePointer) -> Double {
  gtk_adjustment_get_upper(gtkPointer(adjustment) as UnsafeMutablePointer<GtkAdjustment>)
}
func gtk_adjustment_set_value(_ adjustment: OpaquePointer, _ value: Double) {
  gtk_adjustment_set_value(gtkPointer(adjustment) as UnsafeMutablePointer<GtkAdjustment>, value)
}

// MARK: - GtkLabel (NO named Swift type — plain OpaquePointer)
// None of `gtk_label_set_markup`/`_set_text`/`_set_xalign`/`_set_ellipsize`/
// `_set_wrap` need a shim — same reasoning as `gtk_scrolled_window_set_policy`
// above: every parameter already matches the real signature.

// MARK: - GtkImage (NO named Swift type — plain OpaquePointer) / GdkPixbuf
// (also no named type) — `gtk_image_set_pixel_size`/`_set_from_pixbuf` need
// no shim, same reasoning.

// MARK: - GtkButton (a real named type) / GtkToggleButton / GtkCheckButton
func gtk_button_set_icon_name(_ button: OpaquePointer, _ iconName: String) {
  gtk_button_set_icon_name(gtkPointer(button) as UnsafeMutablePointer<GtkButton>, iconName)
}
func gtk_toggle_button_set_group(_ button: OpaquePointer, _ group: OpaquePointer) {
  gtk_toggle_button_set_group(
    gtkPointer(button) as UnsafeMutablePointer<GtkToggleButton>,
    gtkPointer(group) as UnsafeMutablePointer<GtkToggleButton>)
}
func gtk_toggle_button_set_active(_ button: OpaquePointer, _ active: Int32) {
  gtk_toggle_button_set_active(gtkPointer(button) as UnsafeMutablePointer<GtkToggleButton>, active)
}
func gtk_toggle_button_get_active(_ button: OpaquePointer) -> Int32 {
  gtk_toggle_button_get_active(gtkPointer(button) as UnsafeMutablePointer<GtkToggleButton>)
}
func gtk_check_button_set_group(_ button: OpaquePointer, _ group: OpaquePointer) {
  gtk_check_button_set_group(
    gtkPointer(button) as UnsafeMutablePointer<GtkCheckButton>,
    gtkPointer(group) as UnsafeMutablePointer<GtkCheckButton>)
}
func gtk_check_button_set_active(_ button: OpaquePointer, _ active: Int32) {
  gtk_check_button_set_active(gtkPointer(button) as UnsafeMutablePointer<GtkCheckButton>, active)
}
func gtk_check_button_get_active(_ button: OpaquePointer) -> Int32 {
  gtk_check_button_get_active(gtkPointer(button) as UnsafeMutablePointer<GtkCheckButton>)
}

// MARK: - GtkSpinButton (NO named Swift type — plain OpaquePointer)
// `gtk_spin_button_set_value`/`_get_value_as_int` need no shim, same
// reasoning.

// MARK: - GtkEditable (GtkEntry / GtkSearchEntry — NO named Swift type)
// `gtk_editable_get_text`/`_set_text` need no shim, same reasoning.

// MARK: - GtkListBox (NO named Swift type) / GtkListBoxRow (a real named type)
func gtk_list_box_append(_ box: OpaquePointer, _ child: OpaquePointer) {
  gtk_list_box_append(box, gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}
func gtk_list_box_remove(_ box: OpaquePointer, _ child: OpaquePointer) {
  gtk_list_box_remove(box, gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}
// `gtk_list_box_set_selection_mode`/`_unselect_all` need no shim, same
// reasoning as `gtk_scrolled_window_set_policy` above.
func gtk_list_box_select_row(_ box: OpaquePointer, _ row: OpaquePointer) {
  gtk_list_box_select_row(box, gtkPointer(row) as UnsafeMutablePointer<GtkListBoxRow>)
}
func gtk_list_box_get_row_at_index(_ box: OpaquePointer, _ index: Int32) -> OpaquePointer? {
  gtk_list_box_get_row_at_index(box, index).map { OpaquePointer($0) }
}
func gtk_list_box_get_row_at_y(_ box: OpaquePointer, _ y: Int32) -> OpaquePointer? {
  gtk_list_box_get_row_at_y(box, y).map { OpaquePointer($0) }
}
func gtk_list_box_row_get_index(_ row: OpaquePointer) -> Int32 {
  gtk_list_box_row_get_index(gtkPointer(row) as UnsafeMutablePointer<GtkListBoxRow>)
}

// MARK: - GtkNotebook (NO named Swift type — plain OpaquePointer)
func gtk_notebook_append_page(
  _ notebook: OpaquePointer, _ child: OpaquePointer, _ tabLabel: OpaquePointer
) -> Int32 {
  gtk_notebook_append_page(
    notebook, gtkPointer(child) as UnsafeMutablePointer<GtkWidget>,
    gtkPointer(tabLabel) as UnsafeMutablePointer<GtkWidget>)
}

// MARK: - GtkPopover (a real named type)
func gtk_popover_set_autohide(_ popover: OpaquePointer, _ autohide: Int32) {
  gtk_popover_set_autohide(gtkPointer(popover) as UnsafeMutablePointer<GtkPopover>, autohide)
}
func gtk_popover_set_child(_ popover: OpaquePointer, _ child: OpaquePointer) {
  gtk_popover_set_child(
    gtkPointer(popover) as UnsafeMutablePointer<GtkPopover>,
    gtkPointer(child) as UnsafeMutablePointer<GtkWidget>)
}
func gtk_popover_set_pointing_to(_ popover: OpaquePointer, _ rect: inout GdkRectangle) {
  gtk_popover_set_pointing_to(gtkPointer(popover) as UnsafeMutablePointer<GtkPopover>, &rect)
}
func gtk_popover_popup(_ popover: OpaquePointer) {
  gtk_popover_popup(gtkPointer(popover) as UnsafeMutablePointer<GtkPopover>)
}
func gtk_popover_popdown(_ popover: OpaquePointer) {
  gtk_popover_popdown(gtkPointer(popover) as UnsafeMutablePointer<GtkPopover>)
}

// MARK: - GtkEventController (NO named Swift type — plain OpaquePointer)
// `gtk_event_controller_set_propagation_phase` needs no shim, same
// reasoning as `gtk_scrolled_window_set_policy` above.

// MARK: - GdkPixbufLoader (a real named type) / GdkPixbuf (NO named type)
func gdk_pixbuf_loader_set_size(_ loader: OpaquePointer, _ width: Int32, _ height: Int32) {
  gdk_pixbuf_loader_set_size(
    gtkPointer(loader) as UnsafeMutablePointer<GdkPixbufLoader>, width, height)
}
func gdk_pixbuf_loader_write(
  _ loader: OpaquePointer, _ buffer: UnsafePointer<UInt8>, _ count: UInt
) -> Int32 {
  gdk_pixbuf_loader_write(
    gtkPointer(loader) as UnsafeMutablePointer<GdkPixbufLoader>, buffer, count, nil)
}
func gdk_pixbuf_loader_close(_ loader: OpaquePointer) -> Int32 {
  gdk_pixbuf_loader_close(gtkPointer(loader) as UnsafeMutablePointer<GdkPixbufLoader>, nil)
}
func gdk_pixbuf_loader_get_pixbuf(_ loader: OpaquePointer) -> OpaquePointer? {
  gdk_pixbuf_loader_get_pixbuf(gtkPointer(loader) as UnsafeMutablePointer<GdkPixbufLoader>)
}
