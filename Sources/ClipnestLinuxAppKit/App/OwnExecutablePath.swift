import Foundation

/// This process's own absolute executable path.
///
/// Two independent call sites need one — `LinuxAppEnvironment`'s autostart
/// `.desktop` file (`Exec=`) and `LinuxAppLifecycle.installGSettingsFloor()`'s
/// GSettings custom keybinding (`command`) — and both write it into a file or
/// setting that outlives this process, to be executed later by a session
/// component that inherits neither this process's `$PATH` resolution nor its
/// working directory. Getting it wrong is silent: the setting is written
/// successfully and simply never launches anything.
///
/// Reads the `/proc/self/exe` symlink — the kernel-maintained pointer to the
/// running binary's real absolute path, correct regardless of how the process
/// was invoked (bare name resolved via `$PATH`, relative path, absolute path,
/// or through a symlink).
///
/// This exists because the older `CommandLine.arguments.first` + cwd-prefix
/// formula is broken for exactly the case this app ships for. Verified against
/// a real packaged install (P10-A runtime check, Docker): launched as a bare
/// `clipnest` resolved via `$PATH`, `argv[0]` is `"clipnest"` — not an absolute
/// path (so the `hasPrefix("/")` branch is skipped) and not a path component
/// relative to any meaningful cwd (so prepending cwd is wrong), yielding
/// `//clipnest` instead of `/usr/bin/clipnest`. In `installGSettingsFloor` that
/// silently disabled the GSettings custom keybinding — the tier that is the
/// universal hotkey floor for every user without the Shell extension, and the
/// tier the app now falls back to MORE often since `HotkeyBackendResolver`
/// began requiring a live dispatch probe rather than a self-reported
/// capability string.
enum OwnExecutablePath {
  /// Falls back to the literal string `"clipnest"` — relying on `$PATH` at
  /// whatever future moment the `Exec=`/`command` line is actually invoked —
  /// only if `/proc/self/exe` can't be read at all. Not expected on any real
  /// Linux kernel, but neither caller may throw or crash over this.
  static func resolve() -> String {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? "clipnest"
  }
}
