// ClipnestGTKApplication.swift
//
// P7-D (Linux port, GTK4 view layer): process-wide GTK lifecycle — call
// `initializeGTK()` once before constructing any `PickerWindow`/
// `SettingsWindow`, then `runMainLoop()` to hand control to GTK's event
// loop (blocks until `quitMainLoop()`, called from wherever
// `ClipnestLinuxApp` decides the process should exit — e.g. a SIGTERM
// handler or a menu "Quit" action; out of this task's scope).
//
// Uses a plain `GMainLoop` rather than `GtkApplication`/`g_application_run`:
// `ClipnestLinuxApp` (a separate agent's scope, `Sources/ClipnestLinuxApp/**`)
// owns the process's overall lifecycle (tray icon, D-Bus activation, the
// GNOME Shell extension handshake — none of which this task's scope
// touches), so this module only needs "run GTK's event loop" and "stop
// it," not a full `GApplication` with its own command-line/activation
// machinery. `gtk_init()` still registers the default GDK backend and
// initializes GTK's type system exactly as `GtkApplication` would.
//
// No `@MainActor` on this enum: GTK itself has no concept of Swift actor
// isolation, and `ClipnestLinuxApp`'s process entry point is expected to
// call these three functions synchronously, in order, from its own startup
// code (see `PickerWindow.swift`'s top doc comment for the actor-isolation
// reasoning that DOES apply once `PickerViewModel` gets involved, which
// this type never touches).
import CGtk4

public enum ClipnestGTKApplication {
  /// The running main loop, if `runMainLoop()` has been called and hasn't
  /// returned yet — `nonisolated(unsafe)` because it's a raw C pointer
  /// touched only from the single thread that calls `initializeGTK()`/
  /// `runMainLoop()`/`quitMainLoop()` (GTK is not thread-safe to call from
  /// more than one thread regardless; this mirrors how `BlobStore` already
  /// documents `nonisolated(unsafe)` for a type whose real safety
  /// guarantee is "single caller thread," not concurrent access).
  private nonisolated(unsafe) static var mainLoop: OpaquePointer?

  /// Initializes GTK — must be called exactly once, before constructing any
  /// `PickerWindow`/`SettingsWindow`, and before `runMainLoop()`.
  ///
  /// `programName` and `displayName` are set BEFORE `gtk_init()` because
  /// GDK's X11 backend reads `g_get_prgname()` when it builds each toplevel's
  /// `WM_CLASS` (`res_name` verbatim, `res_class` capitalized), and only at
  /// window-realize time — a value set afterwards is silently ignored for
  /// windows already realized.
  ///
  /// Not setting them at all is what this codebase did until a runtime check
  /// on Ubuntu 22.04 caught it: every Clipnest toplevel carried
  /// `WM_CLASS(STRING) = "", ""`, with three consequences, all user-visible.
  /// (1) Nothing associates the running window with the installed
  /// `app.clipnest.Clipnest.desktop`, so the shell shows a fallback icon and
  /// cannot group windows to the launcher. (2)
  /// `LinuxFrontmostApplicationProvider` resolves a source app by
  /// `_GTK_APPLICATION_ID` → `WM_CLASS` → `_NET_WM_NAME`; with the first two
  /// absent it fell all the way through to the window TITLE. (3) Because
  /// `PickerWindow` deliberately sets its title to a per-invocation UUID (its
  /// `windowToken`, the key the GNOME Shell extension matches on — see
  /// `extension/src/core/placement.js`'s `_findByToken`), a clipboard change
  /// captured while the picker held focus was recorded, and then DISPLAYED in
  /// the picker's own source column, as a raw GUID.
  ///
  /// - Parameters:
  ///   - programName: becomes `WM_CLASS`'s `res_name`. Must match the
  ///     `StartupWMClass` in `packaging/linux/desktop/applications/
  ///     app.clipnest.Clipnest.desktop` or the launcher association silently
  ///     does not happen.
  ///   - displayName: `g_set_application_name` — the human-readable name
  ///     GTK/GLib surface in places like an app-chooser or a crash dialog.
  public static func initializeGTK(programName: String, displayName: String) {
    g_set_prgname(programName)
    g_set_application_name(displayName)
    gtk_init()
    installStyle()
  }

  /// Loads `PickerStyleSheet.css` once, for the default `GdkDisplay`, at
  /// `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION` — the exact priority band
  /// meant for an application's own styling (above the active GTK theme,
  /// below anything the user layers on top via `GTK_STYLE_PROVIDER_PRIORITY
  /// _USER`/their own `gtk.css`). Every `PickerWindow`/`SettingsWindow`
  /// instance shares this one provider; neither type loads its own.
  ///
  /// `gtk_css_provider_load_from_data` (not `_load_from_path`/`_load_from_
  /// file`) because the stylesheet is a compiled-in Swift `String`, not a
  /// loose file on disk — see `PickerStyleSheet.swift`'s top doc comment
  /// for why.
  private static func installStyle() {
    let provider = gtk_css_provider_new()
    let css = PickerStyleSheet.css
    css.withCString { cString in
      gtk_css_provider_load_from_data(provider, cString, -1)
    }
    guard let display = gdk_display_get_default() else { return }
    // `gtk_style_context_add_provider_for_display`'s `provider` parameter is
    // declared `GtkStyleProvider*` (an interface Clang couldn't synthesize a
    // named Swift type for, unlike `GtkCssProvider` itself — see
    // `GTKShims.swift`'s top doc comment for this exact per-type quirk) —
    // `OpaquePointer(_:)` is a same-address reinterpretation, not an
    // offsetting cast: GObject interfaces add no data to an instance's
    // layout, only vtable methods looked up via its class, so this is
    // exactly the "GObject subclass pointers are structurally compatible"
    // fact `gtkPointer<T>(_:)` documents, applied in the other direction.
    gtk_style_context_add_provider_for_display(
      display, OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
  }

  /// Runs GTK's event loop on the calling thread until `quitMainLoop()` is
  /// called. Blocks — the conventional shape of every GTK/GLib app's
  /// `main()`.
  public static func runMainLoop() {
    let loop = g_main_loop_new(nil, 0)
    mainLoop = loop
    g_main_loop_run(loop)
    mainLoop = nil
    g_main_loop_unref(loop)
  }

  /// Stops the loop started by `runMainLoop()`, letting it return. A no-op
  /// if no loop is currently running (e.g. called twice, or before
  /// `runMainLoop()`).
  public static func quitMainLoop() {
    guard let mainLoop else { return }
    g_main_loop_quit(mainLoop)
  }
}
