import Foundation

/// Single source of truth for Clipnest's `os.Logger` configuration, shared by
/// `ClipnestCore` and `ClipnestApp`. Every `Logger` is created with
/// `ClipnestLog.subsystem` so the subsystem string lives in exactly one place
/// (coding-standards.md: no magic strings repeated across the codebase).
public enum ClipnestLog {
  /// The `os.Logger` subsystem for all of Clipnest — matches the app's bundle
  /// identifier.
  public static let subsystem = "com.clipnest.app"
}
