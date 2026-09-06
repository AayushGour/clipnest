// GTKShimsForRowActionsAndEditor.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): small GTK API surface
// this task needs that `Interop/GTKShims.swift` doesn't shim yet — this
// task's owned-files scope is `Sources/ClipnestGTK/Window/*.swift` only, not
// `Interop/GTKShims.swift`, so these live here instead. Exact same reasoning
// (and same "verify empirically, don't assume" discipline) as `SettingsWindow
// +Controls.swift`'s own "MARK: - GTK shims not yet in Interop/GTKShims.swift"
// section — see that file's doc comment for the full rationale this mirrors.
// Every constructor returns a plain, already-unwrapped `OpaquePointer`; every
// other function takes `OpaquePointer` and casts internally via `gtkPointer`
// only where the real C signature needs a more specific pointer type — same
// convention `Interop/GTKShims.swift`'s top doc comment documents once for
// the whole module.
//
// `GtkGestureClick`/`GtkGestureSingle` (context-menu right-click detection),
// `GtkTextView`/`GtkTextBuffer` (the snippet editor's multi-line Body field),
// and `GtkEntry`'s placeholder-text setter are new to this module as of this
// task — none was previously exercised by `PickerWindow`/`SettingsWindow`.
//
// Lint note: each function below carries its OWN `// swift-format-ignore:
// AlwaysUseLowerCamelCase` line rather than one file-wide `// swift-format
// -ignore-file: AlwaysUseLowerCamelCase` directive — verified empirically
// (a real `swift format lint --strict` run, not assumed) that this
// toolchain's `lint` subcommand does not honor the file-wide directive at
// all (it still flags every C-named function), while the per-declaration
// directive `SettingsWindow+Controls.swift` already uses IS honored. Matches
// that file's convention exactly, not `Interop/GTKShims.swift`'s (whose
// file-wide directive form appears to be a latent, pre-existing lint gap
// there, outside this task's owned-files scope to fix).
import CGtk4

// MARK: - GtkButton (a real named type, per Interop/GTKShims.swift's survey)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_button_new_from_icon_name(_ iconName: String) -> OpaquePointer {
  OpaquePointer(gtk_button_new_from_icon_name(iconName)!)
}

// MARK: - GtkWidget (a real named type)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_set_sensitive(_ widget: OpaquePointer, _ sensitive: Int32) {
  gtk_widget_set_sensitive(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>, sensitive)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_widget_get_visible(_ widget: OpaquePointer) -> Int32 {
  gtk_widget_get_visible(gtkPointer(widget) as UnsafeMutablePointer<GtkWidget>)
}

// MARK: - GtkWindow (a real named type)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_window_close(_ window: OpaquePointer) {
  gtk_window_close(gtkPointer(window) as UnsafeMutablePointer<GtkWindow>)
}

// MARK: - GtkEntry (a real named type, per Interop/GTKShims.swift's
// `gtk_entry_new()` constructor shim already wrapping its result)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_entry_set_placeholder_text(_ entry: OpaquePointer, _ text: String) {
  gtk_entry_set_placeholder_text(gtkPointer(entry) as UnsafeMutablePointer<GtkEntry>, text)
}

// MARK: - GtkTextView / GtkTextBuffer (new to this module)

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_new() -> OpaquePointer {
  OpaquePointer(gtk_text_view_new()!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_get_buffer(_ textView: OpaquePointer) -> OpaquePointer {
  OpaquePointer(
    gtk_text_view_get_buffer(gtkPointer(textView) as UnsafeMutablePointer<GtkTextView>)!)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_view_set_wrap_mode(_ textView: OpaquePointer, _ mode: GtkWrapMode) {
  gtk_text_view_set_wrap_mode(gtkPointer(textView) as UnsafeMutablePointer<GtkTextView>, mode)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_set_text(_ buffer: OpaquePointer, _ text: String, _ length: Int32) {
  gtk_text_buffer_set_text(gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, text, length)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_get_start_iter(_ buffer: OpaquePointer, _ iter: inout GtkTextIter) {
  gtk_text_buffer_get_start_iter(gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, &iter)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_get_end_iter(_ buffer: OpaquePointer, _ iter: inout GtkTextIter) {
  gtk_text_buffer_get_end_iter(gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, &iter)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_text_buffer_get_text(
  _ buffer: OpaquePointer, _ start: inout GtkTextIter, _ end: inout GtkTextIter,
  _ includeHiddenChars: Int32
) -> UnsafeMutablePointer<CChar>? {
  gtk_text_buffer_get_text(
    gtkPointer(buffer) as UnsafeMutablePointer<GtkTextBuffer>, &start, &end, includeHiddenChars)
}

// MARK: - GtkGestureClick / GtkGestureSingle (new to this module — the
// context menu's right-click detector, `PickerWindow+ContextMenu.swift`)
//
// Verified empirically (a real `swift build` attempt, not assumed — see
// this file's top doc comment): neither `GtkGestureClick` nor
// `GtkGestureSingle` gets its own named Swift type on this GTK 4.6 build —
// the whole `GtkGesture`/`GtkEventController` family is apparently
// consistent on that point (`Interop/GTKShims.swift`'s top doc comment
// already confirmed this for `GtkEventControllerKey`/`Motion`). So
// `gtk_gesture_click_new()` only needs its `OpaquePointer!` force-unwrapped
// (same shape as that file's `gtk_event_controller_key_new()`/
// `_motion_new()` — no `OpaquePointer(...)` wrapping constructor call, which
// is only for types THAT DO get a named type), and
// `gtk_gesture_single_set_button` needs no shim at all: every parameter
// already matches the real imported signature exactly, so a same-named
// wrapper here would just call itself — the identical "infinite recursion"
// class of mistake `Interop/GTKShims.swift`'s own `gtk_scrolled_window
// _set_policy` note already documents. Called directly at its one call
// site (`PickerWindow+ContextMenu.swift`) instead.

// swift-format-ignore: AlwaysUseLowerCamelCase
func gtk_gesture_click_new() -> OpaquePointer {
  gtk_gesture_click_new()!
}
