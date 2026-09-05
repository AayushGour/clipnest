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

/// Platform-neutral logging shim (P1-T5, Linux port prep): wraps `os.Logger`
/// on Apple platforms (`canImport(os)`), exactly like every other `Logger`
/// in this codebase today; on any other platform, `error` prints instead
/// (so a failure is never silently lost) and `info`/`debug` are no-ops
/// (matching `os.Logger`'s own default behavior of not necessarily
/// persisting non-error levels).
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
      print("[\(category)] ERROR: \(message)")
    #endif
  }

  /// Best-effort informational logging; a no-op off Apple platforms.
  public func info(_ message: String) {
    #if canImport(os)
      logger.info("\(message, privacy: .public)")
    #endif
  }

  /// Best-effort debug logging; a no-op off Apple platforms.
  public func debug(_ message: String) {
    #if canImport(os)
      logger.debug("\(message, privacy: .public)")
    #endif
  }
}
