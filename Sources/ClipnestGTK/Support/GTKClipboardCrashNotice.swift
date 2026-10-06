// GTKClipboardCrashNotice.swift
//
// T-WB1-GTKBUMP (routed follow-up, P0 mitigation — decision D81 in
// .claude/project-context.md): GTK4 runtimes before 4.10 crash the WHOLE
// `clipnest` process with a SIGSEGV whenever another X11 client claims a
// TARGETS reply that never actually lands on GDK's window — a real,
// benign, uncommon ICCCM slip, no malice required (reproduced 8-9/10 with
// a hand-written `python-xlib` client; `xclip` never triggered it in 20+
// trials). Root cause, symbolicated against Ubuntu's own gtk4 source and
// `-dbgsym` packages: `g_str_equal(type: NULL, "ATOM")` inside
// `gdk_x11_clipboard_request_targets_got_stream`
// (`gdk/x11/gdkclipboard-x11.c:357`) — `gdk_x11_selection_input_stream_
// xevent` calls `g_task_return_pointer` even when `XGetWindowProperty`
// returned `Success` with `actualType == None` (not an error, just an
// empty reply), and the resulting NULL atom name reaches a NULL-unsafe
// string compare. Fixed upstream by switching to the NULL-safe
// `g_strcmp0` (GNOME/gtk commit `0212291a`), landing in GTK 4.10.0.
//
// There is no opt-out: GDK creates its own CLIPBOARD/PRIMARY tracking
// UNCONDITIONALLY the instant `gtk_init()` opens a display
// (`gdk/x11/gdkdisplay-x11.c`'s `_gdk_x11_display_open`), before any of
// this app's code runs, with no `GDK_DEBUG`/`GDK_DISABLE` flag or
// supported API to avoid it — see T-WB1's task-board entry for the full
// root-cause trail (a live, fully-symbolicated core-dump backtrace, not
// just source inspection). This is therefore a MITIGATION (detect + tell
// the user), not a fix — the real fix is a `libgtk-4-1` version bump,
// which is a packaging decision, not something reachable from this app's
// Swift source (see `debian/README.source`'s "Known gap #5").
//
// Measured, not assumed: Ubuntu 22.04 (jammy) ships `libgtk-4-1` 4.6.9
// (AFFECTED — the official archive, including `-updates`/`-security`, has
// never carried anything newer for this series); Ubuntu 24.04 (noble)
// ships 4.14.5 (FIXED).
//
// This file is the PURE decision layer — mirrors `SessionType`'s own
// pure-`detect`-vs-live-`detectCurrent` split
// (`ClipnestPlatformLinux/Input/SessionType.swift`), and
// `PermissionsTabPresentation`'s pure-decisions-behind-a-GTK-tab split
// (`SettingsWindow+Permissions.swift`): everything below is a plain value
// computed from plain inputs, unit-tested directly with injected version
// numbers, no live GTK/X11 required.
// `Interop/GTKClipboardCrashNoticeDetection.swift` is the untestable
// counterpart that actually reads the running process's real GTK version
// and GDK display backend.

/// A GTK runtime version triple, as reported by `gtk_get_major_version()`/
/// `gtk_get_minor_version()`/`gtk_get_micro_version()` — the version of
/// `libgtk-4-1` actually LOADED at runtime on the machine running this
/// binary. Deliberately never the compile-time `GTK_MAJOR_VERSION`/
/// `GTK_MINOR_VERSION`/`GTK_MICRO_VERSION` macros: those only describe the
/// headers this binary was BUILT against (whatever `libgtk-4-dev` the CI
/// image or packager had installed), a fixed fact of THIS BINARY — not of
/// the machine that eventually RUNS it, which is exactly what
/// distinguishes an Ubuntu 22.04 install (4.6.9 at runtime) from a 24.04
/// one (4.14.5 at runtime), built from the identical source and headers.
public struct GTKRuntimeVersion: Equatable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let micro: Int

  public init(major: Int, minor: Int, micro: Int) {
    self.major = major
    self.minor = minor
    self.micro = micro
  }

  public var description: String { "\(major).\(minor).\(micro)" }

  /// True iff this runtime predates the fix for the X11 CLIPBOARD-ownership
  /// SIGSEGV this file's top doc comment describes. Comparison is
  /// lexicographic on `(major, minor)` only — the micro version never
  /// matters for this cutoff (every 4.10.x release, and every later minor,
  /// carries the fix) — Swift's standard library provides tuple comparison
  /// up to arity 6, so this reads exactly as the version-ordering check it
  /// is.
  public var isAffectedByX11ClipboardCrash: Bool {
    (major, minor) < (4, 10)
  }
}

/// The two live facts the notice's applicability depends on — both
/// resolved ONCE, at process startup (see `GTKClipboardCrashNoticeDetection
/// .detectCurrent()`), since neither can change for the lifetime of this
/// process: the GTK runtime a process has already loaded cannot change
/// underneath it, and GDK picks its backend exactly once, inside
/// `gtk_init()`.
public struct GTKClipboardCrashNoticeInfo: Equatable, Sendable {
  public let runtimeVersion: GTKRuntimeVersion
  /// Whether the ACTUAL, already-opened default `GdkDisplay` is backed by
  /// GDK's X11 backend — queried directly (`GDK_IS_X11_DISPLAY`), never
  /// inferred from `XDG_SESSION_TYPE`/`WAYLAND_DISPLAY` env vars. See
  /// `Sources/CGdkX11/shim.h`'s `clipnest_gdk_display_is_x11` doc comment
  /// for why the live query is necessary rather than an env-var heuristic:
  /// a Wayland session can still end up on the X11 backend if the Wayland
  /// backend fails to initialize, or if `GDK_BACKEND=x11` is forced
  /// (confirmed against GTK's own backend-fallback behavior via
  /// `deepwiki`, not assumed) — an env-var-only check would be a real, if
  /// rare, false negative for exactly the sessions this check exists to
  /// catch.
  public let isX11Backend: Bool

  public init(runtimeVersion: GTKRuntimeVersion, isX11Backend: Bool) {
    self.runtimeVersion = runtimeVersion
    self.isX11Backend = isX11Backend
  }
}

/// Pure presentation logic for the Settings notice — separated from GTK
/// widget code, mirroring `PermissionsTabPresentation`'s identical split,
/// so "should this even show" and the exact copy are unit-tested directly
/// rather than only reachable through a live widget tree.
public enum GTKClipboardCrashNoticePresentation {
  /// The crash this notice warns about is X11-backend-specific — confirmed
  /// via GTK's own source and backend-selection behavior (`gdk/x11/
  /// gdkclipboard-x11.c` is compiled into, and only ever reachable from,
  /// the X11 backend; the Wayland backend has its own, entirely separate
  /// clipboard implementation and never calls into it) — AND only affects
  /// runtimes older than 4.10. Both conditions must hold: an affected
  /// version on Wayland is not at risk, and a current version on X11 has
  /// the fix.
  public static func shouldShow(for info: GTKClipboardCrashNoticeInfo) -> Bool {
    info.isX11Backend && info.runtimeVersion.isAffectedByX11ClipboardCrash
  }

  public static let title = "Clipboard stability notice"

  /// Deliberately non-alarming (per this feature's brief): names what can
  /// happen, states plainly that it is a bug in the SYSTEM's GTK library
  /// rather than in Clipnest, names the exact fixed version, and says
  /// Ubuntu 24.04+ is unaffected — without ever suggesting data loss (the
  /// SQLite-backed clipboard history store survives this crash intact,
  /// confirmed by T-WB1's own container verification: repeated crash
  /// cycles, store integrity reconfirmed both during and after).
  public static func bodyText(for info: GTKClipboardCrashNoticeInfo) -> String {
    "Your system's GTK 4 library (version \(info.runtimeVersion)) has a known bug that can, "
      + "rarely, cause Clipnest to quit unexpectedly when another running application "
      + "interacts with the clipboard in an unusual way. This is a bug in your Linux "
      + "distribution's GTK library — not in Clipnest — and it's already fixed upstream, in "
      + "GTK 4.10 and later; Ubuntu 24.04 and newer already ship a fixed version. Your "
      + "clipboard history is never affected: if this happens, just reopen Clipnest."
  }
}
