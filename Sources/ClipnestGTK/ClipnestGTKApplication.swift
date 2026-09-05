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
  public static func initializeGTK() {
    gtk_init()
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
