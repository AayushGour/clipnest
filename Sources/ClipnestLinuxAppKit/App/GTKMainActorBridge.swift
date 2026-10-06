import CGtk4
import ClipnestGTK
import Foundation

/// Installs the production `DispatchMainQueuePump` tick as a repeating
/// GLib timeout source, so every `@MainActor` hop this app makes actually
/// gets serviced by the one real event loop the process runs
/// (`ClipnestGTKApplication.runMainLoop()`, i.e. `g_main_loop_run`). See
/// `DispatchMainQueuePump`'s doc comment for the mechanism and the
/// empirical evidence it's built on.
///
/// Call `install()` exactly once, AFTER `ClipnestGTKApplication
/// .initializeGTK()` (a live `GMainContext` must exist for
/// `g_timeout_add` to attach to) and BEFORE anything in the composition
/// root performs its first `@MainActor` hop — `LinuxAppLifecycle.run()`
/// does this first, ahead of constructing `LinuxAppEnvironment`.
public enum GTKMainActorBridge {
  /// How often the bridge drains `DispatchQueue.main`. Short enough that a
  /// hotkey press -> `Task { @MainActor in showPicker() }` feels instant
  /// (sub-frame at 120Hz), long enough to be a negligible fraction of one
  /// CPU core when idle — GLib's loop still blocks in `poll()`/`epoll_wait`
  /// between ticks the rest of the time, since a `g_timeout_add` source
  /// (unlike a `g_idle_add` source) does not itself prevent the loop from
  /// sleeping.
  public static let tickIntervalMilliseconds: UInt32 = 8

  /// Guards against `install()` being called more than once per process —
  /// a second timeout source would double-drain harmlessly, but there is
  /// never a legitimate reason to install it twice, so this catches a
  /// composition-root wiring mistake instead of silently tolerating it.
  /// `nonisolated(unsafe)`: touched only from `install()`, itself called
  /// exactly once, synchronously, from `LinuxAppLifecycle.run()` before
  /// any concurrency machinery (this bridge included) exists to make a
  /// second, concurrent call possible — mirrors `ClipnestGTKApplication
  /// .mainLoop`'s identical "single caller thread by construction, not
  /// concurrent access" justification.
  private nonisolated(unsafe) static var isInstalled = false

  public static func install() {
    guard !isInstalled else { return }
    isInstalled = true
    _ = g_timeout_add(
      tickIntervalMilliseconds,
      { _ in
        DispatchMainQueuePump.drainOnce()
        return gboolean(1)  // G_SOURCE_CONTINUE — keep ticking for the app's lifetime.
      }, nil)
  }
}
