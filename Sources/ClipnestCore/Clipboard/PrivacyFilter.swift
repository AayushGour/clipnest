import Foundation

/// Decides whether a pasteboard change should be captured.
///
/// Concealed/transient pasteboard markers and the paused flag are checked first
/// and reject unconditionally — no parameter combination can bypass them. This
/// is a security-critical invariant: see `.claude/coding-standards.md`'s
/// "Privacy / security musts."
public struct PrivacyFilter: Sendable {
  #if os(macOS)
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
  #else
    /// T-BUG3 (parity-audit bug #3): the macOS bundle-ID list above can
    /// never match on Linux — `LinuxFrontmostApplicationProvider
    /// .frontmostBundleID` (out of this file's scope) resolves to
    /// `_GTK_APPLICATION_ID` when the frontmost app set one, falling back
    /// to `WM_CLASS`'s CLASS component otherwise; neither has any relation
    /// to a macOS reverse-DNS bundle ID. This is the Linux equivalent list,
    /// matched case-insensitively by `shouldCapture` below (unlike a
    /// macOS bundle ID, a window-manager class name's casing isn't a
    /// stable, tooling-enforced contract — it varies by toolkit/packaging).
    ///
    /// Per-entry verification (this task's decision log has the full
    /// detail):
    /// - `"keepassxc"` / `"org.keepassxc.KeePassXC"`: read directly from
    ///   KeePassXC's own source (`keepassxreboot/keepassxc`) —
    ///   `share/linux/org.keepassxc.KeePassXC.desktop.in` sets
    ///   `StartupWMClass=keepassxc` (its real X11 WM_CLASS, both
    ///   instance and class), and `main()` calls
    ///   `QGuiApplication::setDesktopFileName("org.keepassxc.KeePassXC")`
    ///   (its desktop-file id — the closest thing it could report as a
    ///   `_GTK_APPLICATION_ID`-style identifier, e.g. under Flatpak).
    /// - `"com.bitwarden.desktop"`: read directly from Bitwarden's own
    ///   source (`bitwarden/clients`) — `electron-builder.json`'s Linux
    ///   `appId` and `apps/desktop/resources/com.bitwarden.desktop.desktop`'s
    ///   `StartupWMClass` are both `com.bitwarden.desktop`; a `.desktop`
    ///   file's `StartupWMClass` only works for window-manager/taskbar
    ///   grouping if it equals the app's actual runtime WM_CLASS, so this
    ///   is confirmed, not inferred. `"bitwarden"` is kept alongside it as
    ///   a fallback for Electron's own un-overridden lowercase default.
    /// - `"org.gnome.World.Secrets"`: GNOME Secrets' Flathub/application
    ///   ID — a native GTK4/libadwaita app reports its `Adw.Application`
    ///   id directly as `_GTK_APPLICATION_ID`, which
    ///   `LinuxFrontmostApplicationProvider` already prioritizes first.
    /// - `"1password"` / `"enpass"`: 1Password 8 and Enpass are
    ///   closed-source, so there is no public repository to read a
    ///   `StartupWMClass`/appId from directly; both values are each app's
    ///   own consistently-documented Linux product/window name (matching
    ///   the same "product name becomes the window class" convention
    ///   confirmed above for Bitwarden). Flagged as the lower-confidence
    ///   entries in this list — worth a real-install `xprop WM_CLASS`
    ///   spot-check as a fast follow, not blocking this fix (case-
    ///   insensitive matching already covers the likeliest casing
    ///   variants either way).
    public static let builtInExcludedBundleIDs: Set<String> = [
      "keepassxc",
      "org.keepassxc.KeePassXC",
      "com.bitwarden.desktop",
      "bitwarden",
      "1password",
      "org.gnome.World.Secrets",
      "enpass",
    ]
  #endif

  /// The `org.nspasteboard` marker apps set to say "don't record this" (password
  /// managers, etc). Public + shared so tests reference the same constant instead
  /// of duplicating the raw string — see coding-standards.md's no-magic-strings rule.
  public static let concealedPasteboardType = ClipMediaType.concealed

  /// The `org.nspasteboard` marker apps set to say "this is short-lived, don't
  /// record it" (e.g. an OTP that's about to be overwritten).
  public static let transientPasteboardType = ClipMediaType.transient

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
    availableTypes: [ClipMediaType],
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

    // T-BUG3: case-insensitive — a macOS bundle ID's casing is a stable,
    // tooling-enforced contract (always effectively lowercase reverse-DNS),
    // but a Linux `_GTK_APPLICATION_ID`/WM_CLASS CLASS component's casing
    // varies by toolkit/packaging (e.g. Bitwarden's own real WM_CLASS is
    // "com.bitwarden.desktop", but nothing here can guarantee every
    // password manager or window manager reports it in exactly that case),
    // so an exact-match `Set.contains` would silently miss real matches.
    // Applied uniformly rather than only under `#if !os(macOS)` — it's a
    // pure widening (never causes an exact-match exclusion to stop
    // firing), so every macOS case that used to match still matches.
    if let sourceBundleID,
      Self.builtInExcludedBundleIDs.union(customExcludedBundleIDs).contains(where: {
        $0.caseInsensitiveCompare(sourceBundleID) == .orderedSame
      })
    {
      return false
    }

    return true
  }
}
