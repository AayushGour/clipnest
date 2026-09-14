// ProcessSignalShutdown.swift
//
// T-IBUS-CRASHWIRE: wires SIGTERM/SIGINT to the crash-safety restore path.
// **Genuinely new infrastructure** — there was no signal handler of any
// kind anywhere in this codebase before this task; shutdown was only ever
// the tray's "Quit" item -> `ClipnestGTKApplication.quitMainLoop()` (see
// that type's own top doc comment, which already anticipated this: "called
// from wherever ClipnestLinuxApp decides the process should exit — e.g. a
// SIGTERM handler or a menu Quit action; out of this task's scope" — that
// "out of scope" is this task).
//
// ## Why this exists (D-IBUS-3)
// Clipnest's IBus snippet-expansion tier briefly switches the GLOBAL IBus
// engine to its own, commits, then switches back
// (`IBusCommitTransaction`). If this process dies between those two steps,
// the user is left on a dead engine and cannot type until they notice and
// fix it manually — this happened for real during this feature's own POC
// development (a registration bug crashed the engine process).
// `IBusCrashSafetyStateMachine` already persists a marker before switching
// and clears it only after a CONFIRMED restore; this file gives a process
// being asked to stop gracefully (SIGTERM, or Ctrl-C's SIGINT) a chance to
// run that restore BEFORE it actually exits, rather than always relying on
// the NEXT launch's own startup reconciliation
// (`LinuxAppLifecycle.launch` -> `IBusCrashSafetyReconciler
// .restoreIfMarkerPresent`) to repair it.
//
// ## The self-pipe design — why, not just what
// Only `write()` — and nothing else — is legal inside a raw OS signal
// handler that may have interrupted arbitrary code, including the
// allocator, mid-operation: no logging, no GLib call, no Swift runtime
// call of any kind is guaranteed safe there. coding-standards.md already
// mandates deferring GTK signal-handler work to the next GLib idle
// iteration rather than acting synchronously inside the handler; this is
// the identical shape with a new trigger (a real POSIX signal, not a
// GObject one), and the self-pipe trick is the standard way to bridge the
// two: the signal handler writes one byte to a pipe
// (`selfPipePostWakeupAsyncSignalSafe`, async-signal-safe by construction
// — see `SelfPipe.swift`), and a `GIOChannel` watch on the pipe's read end
// (`g_io_add_watch`, attached to the SAME `GMainContext` the app's one
// real event loop already runs on) dispatches the actual
// restore-if-needed + quit logic once that byte arrives — running as an
// ordinary GLib main-loop callback, on the same thread every other
// `@MainActor` hop in this app already assumes (`MainActor.assumeIsolated`,
// matching `PickerWindow+Reconcile.swift`/`SettingsWindow+History.swift`'s
// existing trampoline precedent).
//
// ## What this covers, and what it plainly does not
// SIGTERM and SIGINT — the two signals an ordinary `kill`/process
// supervisor/systemd stop, or Ctrl-C, actually send. **SIGKILL is
// uncatchable by definition: no in-process hook, here or anywhere else,
// can run before a SIGKILLed process's address space simply vanishes.**
// This file does not claim otherwise. The mitigation for SIGKILL — and for
// this handler simply losing the race, or IBus being unreachable at the
// moment of the signal — is layered elsewhere, not here:
// `LinuxAppLifecycle.launch`'s startup reconciliation repairs a marker
// left dangling by ANY cause on the NEXT launch, and IBus's own
// daemon-side disconnect detection (noticing our socket close at the
// kernel level) is independent of this app doing anything at all.
import CGtk4
import ClipnestCore

/// Catches SIGTERM/SIGINT via a self-pipe and defers all real work to the
/// GLib main loop. No `@MainActor` on this enum — the same reasoning
/// `ClipnestGTKApplication`'s own doc comment gives: this type's static
/// state is touched only from `install()` (called once, synchronously,
/// from `LinuxAppLifecycle.run()`, before any concurrency machinery
/// exists) and from the raw C callbacks below, which run on the single
/// GTK/GLib thread this whole app assumes.
enum ProcessSignalShutdown {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "ProcessSignalShutdown")

  /// Guards `install()` against being called more than once per process —
  /// mirrors `GTKMainActorBridge.isInstalled`'s identical reasoning and
  /// `nonisolated(unsafe)` justification.
  private nonisolated(unsafe) static var isInstalled = false

  /// The self-pipe itself — deliberately a bare, process-lifetime global,
  /// never threaded through an instance: `shutdownSignalHandler` below is
  /// a `@convention(c)` function pointer, which by definition cannot
  /// capture anything, so a global is the only way it can reach the fd to
  /// write to. Assigned exactly once, by `install()`, BEFORE `sigaction`
  /// is ever installed; read-only from every signal-handler invocation
  /// after that point, which is what makes a plain global safe here
  /// despite running on a signal-interrupted thread — a value that is
  /// never concurrently WRITTEN once installation has completed is not a
  /// data race under POSIX's own async-signal-safety rules.
  private nonisolated(unsafe) static var selfPipe: SelfPipe?

  /// The caller-supplied shutdown action — required, no default. Matches
  /// `reinstallToggleHotkeyFloor`/`requestUInputGrant`'s existing
  /// "cross-boundary seam gets no silent no-op default" precedent
  /// (coding-standards.md): a `ProcessSignalShutdown` wired with nothing
  /// to call would silently catch SIGTERM/SIGINT and then do nothing,
  /// which is strictly worse than not catching them at all (the process
  /// would never exit on a plain `kill`, since the default terminate
  /// action was just overridden with a real handler that goes nowhere).
  private nonisolated(unsafe) static var onShutdownSignal: (@MainActor () -> Void)?

  /// Installs SIGTERM/SIGINT handling and the GLib-side dispatch that
  /// drains it. Call exactly once, AFTER `ClipnestGTKApplication
  /// .initializeGTK()` (a live `GMainContext` must exist for
  /// `g_io_add_watch` to attach to — same requirement
  /// `GTKMainActorBridge.install()` already documents for its own
  /// `g_timeout_add` source) and as early as practical after that, so the
  /// window before a signal is actually caught is as small as this
  /// process's own startup allows.
  ///
  /// `onShutdownSignal` runs on the GTK main-loop thread — never inside
  /// the raw OS signal handler, see this type's top doc comment — once
  /// EITHER signal is caught, with the pipe already drained. It is the
  /// caller's job to restore-if-needed and then actually quit; kept as an
  /// injected closure (not a hardcoded call to
  /// `ClipnestGTKApplication.quitMainLoop()`) so this file stays decoupled
  /// from `LinuxAppLifecycle`'s specific shutdown sequence — the SAME
  /// shared routine the tray's "Quit" item calls, per this task's own
  /// brief ("graceful quit and signal quit share one path rather than
  /// drifting apart").
  ///
  /// Silently degrades (logging only) if the self-pipe itself cannot be
  /// created — SIGTERM/SIGINT then fall back to their default (uncaught
  /// -> terminate) behavior, exactly as they did in this codebase before
  /// this task existed, which is no worse than the pre-T-IBUS-CRASHWIRE
  /// status quo.
  static func install(onShutdownSignal: @escaping @MainActor () -> Void) {
    guard !isInstalled else { return }
    isInstalled = true
    Self.onShutdownSignal = onShutdownSignal

    guard let pipe = SelfPipe.create() else {
      logger.error(
        "install: failed to create the self-pipe — SIGTERM/SIGINT fall back to default (uncaught) termination behavior this session"
      )
      return
    }
    selfPipe = pipe

    installSignalHandlers()
    installGLibDispatch(readFileDescriptor: pipe.readFileDescriptor)
    logger.info("install: SIGTERM/SIGINT now route through the crash-safety restore path")
  }

  #if canImport(Glibc)
    /// The ONLY work legal inside this handler is the one `write()` call
    /// `selfPipePostWakeupAsyncSignalSafe` performs — see this type's top
    /// doc comment and `SelfPipe.swift`'s doc comment on that function for
    /// exactly why. `selfPipe`'s optional-chained read (never a
    /// force-unwrap) degrades a signal arriving before `install()` has
    /// finished assigning it — structurally impossible in practice
    /// (`sigaction` is only ever installed AFTER `selfPipe` is assigned,
    /// on the same synchronous, single-threaded startup path) — to a
    /// silently dropped wakeup rather than a crash, matching this
    /// codebase's "never a force-unwrap, even for the impossible case"
    /// standard (coding-standards.md).
    private static let shutdownSignalHandler: @convention(c) (Int32) -> Void = { _ in
      guard let writeFileDescriptor = ProcessSignalShutdown.selfPipe?.writeFileDescriptor else {
        return
      }
      selfPipePostWakeupAsyncSignalSafe(writeFileDescriptor: writeFileDescriptor)
    }

    private static func installSignalHandlers() {
      var action = sigaction()
      action.__sigaction_handler = .init(sa_handler: shutdownSignalHandler)
      action.sa_flags = 0
      sigemptyset(&action.sa_mask)
      _ = sigaction(SIGTERM, &action, nil)
      _ = sigaction(SIGINT, &action, nil)
    }

    private static func installGLibDispatch(readFileDescriptor: Int32) {
      let channel = g_io_channel_unix_new(readFileDescriptor)
      _ = g_io_add_watch(channel, G_IO_IN, shutdownIOWatchCallback, nil)
      // `g_io_add_watch` takes its own reference to `channel` — release
      // this call's local one so the watch (not this function) owns its
      // lifetime from here on. Standard GLib ref-counting hygiene, not
      // load-bearing for correctness (a leaked single `GIOChannel` for the
      // process's whole life would be harmless, just untidy).
      g_io_channel_unref(channel)
    }

    /// `GIOFunc` — `gboolean (*)(GIOChannel*, GIOCondition, gpointer)`.
    /// Runs on the GLib main loop (the GTK thread), never inside the raw
    /// signal handler — this is where it's actually safe to drain the
    /// pipe, run the restore-if-needed routine, and quit.
    private static let shutdownIOWatchCallback: GIOFunc = { _, _, _ in
      ProcessSignalShutdown.selfPipe?.drain()
      if let callback = ProcessSignalShutdown.onShutdownSignal {
        MainActor.assumeIsolated {
          callback()
        }
      }
      // G_SOURCE_REMOVE: this app has exactly one `GMainLoop`, and
      // `onShutdownSignal` is expected to quit it — nothing is left to
      // watch for after this fires.
      return gboolean(0)
    }
  #else
    private static func installSignalHandlers() {}
    private static func installGLibDispatch(readFileDescriptor: Int32) {}
  #endif
}
