import Foundation

#if canImport(os)
  import os
#endif

/// Single source of truth for Clipnest's `os.Logger` configuration, shared by
/// `ClipnestCore` and `ClipnestApp`. Every `Logger` is created with
/// `ClipnestLog.subsystem` so the subsystem string lives in exactly one place
/// (coding-standards.md: no magic strings repeated across the codebase).
public enum ClipnestLog {
  /// The `os.Logger` subsystem for all of Clipnest — matches the app's bundle
  /// identifier.
  public static let subsystem = "com.clipnest.app"
}

/// Platform-neutral logging shim (P1-T5, Linux port prep; T-LX2 fix): wraps
/// `os.Logger` on Apple platforms (`canImport(os)`), exactly like every
/// other `Logger` in this codebase today; on any other platform, every
/// level (`error`/`info`/`debug`) writes one line to **stderr** via
/// `FileHandle.standardError` — a raw `write(2)`, never buffered C stdio,
/// so a line is never silently lost even if the process is killed a moment
/// later (see T-LX2's fix note below for why that distinction mattered).
///
/// **T-LX2 (2026-09):** the Linux app used to emit ZERO output — no
/// startup line, no error, nothing on stdout or stderr — which is what
/// made T-LX1 (the D-Bus control service silently never answering calls)
/// so hard to diagnose. Two separate bugs combined to cause that: (1)
/// `info`/`debug` were flat no-ops off Apple platforms (see the old doc
/// comment this replaces), so the many `logger.info(...)` calls in
/// `LinuxAppLifecycle` never had a chance; (2) even `error`'s `print(...)`
/// wrote to **stdout**, which — unlike stderr — is fully block-buffered by
/// C stdio whenever it isn't a TTY (e.g. redirected to a file/pipe, or a
/// systemd/D-Bus-activated service's own stdout), so nothing would
/// actually reach the terminal/log until the buffer filled or the process
/// exited cleanly; a `while true` GTK main loop killed by a signal never
/// gets that chance. Switching to a direct, unbuffered stderr write fixes
/// both: every level now actually emits, and it's never swallowed by
/// buffering. journald captures a systemd service's stderr automatically
/// (`StandardError=journal` is systemd's own default) — nothing extra
/// needed here for that, and adding real libsystemd/journald bindings
/// would need a new system-library target declared in `Package.swift`,
/// which is out of scope for this fix.
///
/// Exists so platform-neutral code extracted for the Linux port (e.g.
/// `StoreFileRecovery`, which deliberately takes a plain `(String) -> Void`
/// closure rather than depending on this type directly — see its own doc
/// comment) has a concrete, reusable logger type available when a future
/// caller wants one, without pulling `os` into that platform-neutral code
/// itself.
///
/// **Metadata-only, same discipline as every existing `os.Logger` call site**
/// (coding-standards.md's privacy rule): this type accepts only plain
/// `String` messages (no `os.Logger`'s `privacy:` interpolation API, which
/// is Apple-only) — callers must never pass raw clipboard content
/// (`previewText`, blob bytes), only metadata (`ItemKind`, `byteSize`, a
/// truncated/hashed identifier, an error description).
///
/// Deliberately NOT wired into any existing `os.Logger` call site by this
/// task (P1-T4/P1-T5) — `Clipboard/`/`Paste/`'s call sites belong to a
/// parallel agent this session, and converting `Store/`'s own call sites was
/// left undone too, to keep this change purely additive; see
/// project-context.md's P1-T5 decision for the full rationale.
public struct ClipnestLogger: Sendable {
  private let category: String
  #if canImport(os)
    private let logger: Logger
  #endif

  public init(subsystem: String, category: String) {
    self.category = category
    #if canImport(os)
      self.logger = Logger(subsystem: subsystem, category: category)
    #endif
  }

  /// Always surfaces, on every platform — errors are never dropped.
  public func error(_ message: String) {
    #if canImport(os)
      logger.error("\(message, privacy: .public)")
    #else
      Self.emit(level: "ERROR", category: category, message: message)
    #endif
  }

  /// Always surfaces, on every platform (see this type's doc comment for
  /// why this used to be a no-op off Apple platforms, and no longer is).
  public func info(_ message: String) {
    #if canImport(os)
      logger.info("\(message, privacy: .public)")
    #else
      Self.emit(level: "INFO", category: category, message: message)
    #endif
  }

  /// Always surfaces, on every platform (see this type's doc comment for
  /// why this used to be a no-op off Apple platforms, and no longer is).
  public func debug(_ message: String) {
    #if canImport(os)
      logger.debug("\(message, privacy: .public)")
    #else
      Self.emit(level: "DEBUG", category: category, message: message)
    #endif
  }

  #if !canImport(os)
    /// Writes one `"[category] LEVEL: message\n"` line straight to file
    /// descriptor 2 (`write(2)`, via `FileHandle.standardError` — never
    /// buffered C stdio) so it is never lost to stdout's buffering or to a
    /// no-op level. `write(2)` for a single call this small is atomic with
    /// respect to other writers on the same fd, so concurrent callers
    /// (this service's receive-loop thread, the main thread, etc.) don't
    /// interleave mid-line.
    private static func emit(level: String, category: String, message: String) {
      let line = "[\(category)] \(level): \(message)\n"
      FileHandle.standardError.write(Data(line.utf8))
    }
  #endif
}
