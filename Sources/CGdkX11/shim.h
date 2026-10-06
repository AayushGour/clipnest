// T-RT4 (Linux port, GTK4 view layer): a SEPARATE system-library module from
// `CGtk4` (not an addition to that module's `shim.h`) so the X11-backend-
// specific `<gdk/x11/gdkx.h>` header — and its extra link dependency on
// libX11 — is opt-in per target, not forced onto every `CGtk4` consumer.
// `ClipnestGTK` is the only consumer today (see `Package.swift`).
//
// Only ever built on Linux (`Package.swift`'s `#if os(Linux)` guard around
// this whole target's declaration), where `libgtk-4-dev`'s X11 backend
// support is compiled in by default on every target distro this project
// supports (verified: Ubuntu 22.04's `libgtk-4-dev` package) — hence the
// `#ifdef GDK_WINDOWING_X11` below is realistically always true at COMPILE
// time here. It still exists, and is still checked, because compile-time
// backend support and the RUNTIME backend a given session actually uses are
// two different questions — a Wayland session can absolutely run atop a GTK
// build that also has X11 support compiled in. That is exactly why
// `clipnest_gtk_window_set_x11_utility_type_hint` below ALSO checks
// `GDK_IS_X11_SURFACE` at runtime before touching any X property, and
// returns 0 (a pure no-op, not a crash) whenever that check fails — see
// that function's own doc comment.
#ifndef CLIPNEST_CGDKX11_SHIM_H
#define CLIPNEST_CGDKX11_SHIM_H

#include <gtk/gtk.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xatom.h>
#endif

/// Sets `_NET_WM_WINDOW_TYPE` to `_NET_WM_WINDOW_TYPE_UTILITY` on `window`'s
/// underlying X11 surface — see the port plan's "Window placement" section:
/// this is what makes mutter's `meta_window_place()` `goto done`, honoring
/// this app's own requested picker position instead of applying its own
/// placement heuristics (verified against mutter's `src/core/place.c`).
///
/// Realizes `window` first if it hasn't been already (`gtk_widget_realize`
/// creates the underlying `GdkSurface` without mapping/showing the window —
/// safe to call from `PickerWindow.init`, well before the window is ever
/// presented, which is exactly when the caller uses this: mutter reads
/// `_NET_WM_WINDOW_TYPE` at PLACEMENT time, i.e. the window's first map, so
/// the property must already be set before that first `gtk_window_present`).
///
/// A pure no-op on any non-X11 backend (Wayland, or the compile-time
/// `#else` branch below) — returns 0 rather than crashing, exactly per
/// this task's contract. Returns 1 iff the property was actually set.
static inline int clipnest_gtk_window_set_x11_utility_type_hint(GtkWidget *window) {
#ifdef GDK_WINDOWING_X11
  gtk_widget_realize(window);
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
  if (surface == NULL || !GDK_IS_X11_SURFACE(surface)) {
    return 0;
  }
  GdkDisplay *gdkDisplay = gdk_surface_get_display(surface);
  Display *xDisplay = GDK_DISPLAY_XDISPLAY(gdkDisplay);
  Window xWindow = gdk_x11_surface_get_xid(surface);
  Atom windowTypeAtom = gdk_x11_get_xatom_by_name_for_display(gdkDisplay, "_NET_WM_WINDOW_TYPE");
  Atom utilityAtom =
      gdk_x11_get_xatom_by_name_for_display(gdkDisplay, "_NET_WM_WINDOW_TYPE_UTILITY");
  XChangeProperty(
      xDisplay, xWindow, windowTypeAtom, XA_ATOM, 32, PropModeReplace,
      (unsigned char *)&utilityAtom, 1);
  return 1;
#else
  (void)window;
  return 0;
#endif
}

/// T-WB1-GTKBUMP (X11 CLIPBOARD-ownership SIGSEGV mitigation, decision D81):
/// true iff `display` is GDK's X11 backend (`GdkX11Display`) — the ONLY
/// backend that ever calls into `gdk/x11/gdkclipboard-x11.c`, where the
/// NULL-unsafe `g_str_equal` crash lives (fixed upstream in GTK 4.10, commit
/// `0212291a`). Queries the REAL, already-opened `GdkDisplay` at runtime
/// rather than inferring from `XDG_SESSION_TYPE`/`WAYLAND_DISPLAY` — a
/// Wayland session can still end up on the X11 backend if the Wayland
/// backend fails to initialize, or if `GDK_BACKEND=x11` is forced
/// (`gdk_display_manager_open_display`'s documented fallback behavior), so
/// an env-var heuristic alone would be a real, if rare, false negative for
/// exactly the sessions this check exists to catch.
///
/// A pure no-op (returns 0) on `display == NULL` or the compile-time `#else`
/// branch — mirrors `clipnest_gtk_window_set_x11_utility_type_hint` above.
static inline int clipnest_gdk_display_is_x11(GdkDisplay *display) {
#ifdef GDK_WINDOWING_X11
  return display != NULL && GDK_IS_X11_DISPLAY(display) ? 1 : 0;
#else
  (void)display;
  return 0;
#endif
}

#endif
