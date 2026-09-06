// X11WindowTypeHint.swift
//
// T-RT4 (Linux port, GTK4 view layer): the one call site
// `PickerWindow.init` needs to set `_NET_WM_WINDOW_TYPE_UTILITY` on X11 —
// see `Sources/CGdkX11/shim.h`'s `clipnest_gtk_window_set_x11_utility_type_
// hint` doc comment for the full mechanism (realize, check
// `GDK_IS_X11_SURFACE` at runtime, `XChangeProperty`) and why it is a pure
// no-op under Wayland rather than a crash.
//
// Deliberately NOT added to `GTKShims.swift`: that file is reserved for
// same-named Swift overloads of REAL GTK/GDK/GLib functions (see its top
// doc comment) — `clipnest_gtk_window_set_x11_utility_type_hint` is this
// module's own C helper, not one of those, so it gets its own small file
// instead, matching how every other non-1:1-shim helper in `Interop/` is
// split out.
//
// UNTESTABLE GTK EDGE: like `PickerWindow+Reconcile.swift`'s
// `scheduleCoalescedRefresh()` (which actually calls `g_idle_add_full`),
// this function's entire body is a real GTK/X11 side effect with no real
// display to run `swift test` against — there is no pure decision inside
// it left to unit-test. Verified instead at runtime (see this task's own
// verification: `xprop`/`wmctrl` against the live picker window in
// `packaging/linux/vnc`'s container).
import CGdkX11
import CGtk4

/// Sets `_NET_WM_WINDOW_TYPE_UTILITY` on `window`'s underlying X11 surface,
/// realizing it first if needed — see this file's top doc comment. Returns
/// `true` iff the property was actually set (i.e. the running session is
/// really on X11); `false` on Wayland or any other non-X11 backend, which
/// is the expected, non-error outcome there.
@discardableResult
func gtkWindowSetX11UtilityTypeHint(_ window: OpaquePointer) -> Bool {
  let widget = gtkPointer(window) as UnsafeMutablePointer<GtkWidget>
  return clipnest_gtk_window_set_x11_utility_type_hint(widget) != 0
}
