import AppKit
import Foundation

/// Decides whether a pasteboard change should be captured.
///
/// Concealed/transient pasteboard markers and the paused flag are checked first
/// and reject unconditionally — no parameter combination can bypass them. This
/// is a security-critical invariant: see `.claude/coding-standards.md`'s
/// "Privacy / security musts."
public struct PrivacyFilter: Sendable {
  /// Well-known bundle identifiers for password managers, auto-excluded from
  /// capture regardless of any caller-supplied custom list. Verified via web
  /// search at implementation time (2026-08-06) rather than guessed from
  /// memory — see the task report for source notes and confidence per entry.
  public static let builtInExcludedBundleIDs: Set<String> = [
    "com.1password.1password",  // 1Password 8 (current)
    "com.agilebits.onepassword7",  // 1Password 7 (legacy, still in use)
    "com.bitwarden.desktop",  // Bitwarden desktop app
    "com.lastpass.LastPass",  // LastPass desktop app
    "com.dashlane.Dashlane",  // Dashlane desktop app
    "com.callpod.keeper",  // Keeper Password Manager (Callpod Inc.)
  ]

  /// The `org.nspasteboard` marker apps set to say "don't record this" (password
  /// managers, etc). Public + shared so tests reference the same constant instead
  /// of duplicating the raw string — see coding-standards.md's no-magic-strings rule.
  public static let concealedPasteboardType = NSPasteboard.PasteboardType(
    "org.nspasteboard.ConcealedType")

  /// The `org.nspasteboard` marker apps set to say "this is short-lived, don't
  /// record it" (e.g. an OTP that's about to be overwritten).
  public static let transientPasteboardType = NSPasteboard.PasteboardType(
    "org.nspasteboard.TransientType")

  public init() {}

  /// Returns `true` when a pasteboard change should be captured.
  ///
  /// - Parameters:
  ///   - availableTypes: The pasteboard types present on the change being evaluated.
  ///   - sourceBundleID: The bundle identifier of the app that produced the change, if known.
  ///   - isPaused: Whether the user has paused capture.
  ///   - customExcludedBundleIDs: A caller-supplied set of additional excluded bundle IDs
  ///     (e.g. from Settings). This can only ever *add* exclusions, never remove the
  ///     built-in ones or the concealed/transient check.
  public func shouldCapture(
    availableTypes: [NSPasteboard.PasteboardType],
    sourceBundleID: String?,
    isPaused: Bool,
    customExcludedBundleIDs: Set<String> = []
  ) -> Bool {
    // Unconditional, unbypassable: no parameter can override this check.
    guard
      !availableTypes.contains(Self.concealedPasteboardType),
      !availableTypes.contains(Self.transientPasteboardType)
    else {
      return false
    }

    guard !isPaused else { return false }

    if let sourceBundleID,
      Self.builtInExcludedBundleIDs.union(customExcludedBundleIDs).contains(sourceBundleID)
    {
      return false
    }

    return true
  }
}
