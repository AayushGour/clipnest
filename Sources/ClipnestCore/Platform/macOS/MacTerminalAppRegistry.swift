#if os(macOS)
  import Foundation

  /// Bundle identifiers of terminal emulators known to disconnect a
  /// mouse-drag text "selection" from the shell's real cursor position — see
  /// `SelectionReplaceResult.declinedTerminalTarget`'s doc comment (T-
  /// TERMPASTE1) for the full writeup of why that makes the clipboard-borrow
  /// copy-then-paste-with-no-delete-step transaction corrupt text there
  /// instead of replacing it.
  ///
  /// This is NOT a port of the Linux `TerminalAppRegistry`
  /// (`Sources/ClipnestPlatformLinux/Input/TerminalAppRegistry.swift`) and
  /// doesn't share its vocabulary (macOS bundle identifiers vs. Linux
  /// WM_CLASS/desktop-file identifiers) — that type exists for a DIFFERENT
  /// reason entirely (picking Ctrl+Shift+C/V over plain Ctrl+C/V, since
  /// plain Ctrl+C sends SIGINT in an X11/Wayland terminal). ⌘C/⌘V need no
  /// modifier swap in ANY macOS terminal — copy/paste itself always works
  /// fine there — so this type only ever answers yes/no ("is this target a
  /// terminal, so the fallback tier must decline"), never a chord. Only the
  /// SHAPE is shared (a `Set<String>`, kept in exactly one place per
  /// coding-standards.md's "no magic strings" rule).
  public enum MacTerminalAppRegistry {
    /// Verified against each project's own build metadata at implementation
    /// time (2026-09-14) — not guessed:
    /// - `com.apple.Terminal` — Apple's own Terminal.app, well-known.
    /// - `com.googlecode.iterm2` — iTerm2's `plists/release-iTerm2.plist`
    ///   (all of iTerm2's dev/beta/nightly/preview build plists agree).
    /// - `dev.warp.Warp-Stable` — Warp's `app/Cargo.toml`
    ///   `[package.metadata.bundle.bin.stable]` (the stable release
    ///   channel actually shipped to users; `-Preview`/`-Dev`/`-Local`/
    ///   `WarpOss` are other channels, not the default download).
    /// - `net.kovidgoyal.kitty` — kitty's `setup.py` `macos_info_plist`.
    /// - `org.alacritty` / `io.alacritty` — Alacritty's `Info.plist`;
    ///   `CHANGELOG.md` records the rename from `io.alacritty` to
    ///   `org.alacritty` at 0.11.0, so both are listed to still catch an
    ///   older install.
    /// - `com.github.wez.wezterm` — WezTerm's
    ///   `assets/macos/WezTerm.app/Contents/Info.plist` (its Flatpak/
    ///   AppData identifier, `org.wezfurlong.wezterm`, is a DIFFERENT
    ///   packaging format's id, not this one).
    /// - `com.mitchellh.ghostty` — Ghostty's
    ///   `macos/Ghostty.xcodeproj/project.pbxproj` Release configuration
    ///   (`.debug` builds use a distinct suffixed id, intentionally not
    ///   listed here — an end user never runs a Debug-signed Ghostty).
    public static let terminalBundleIdentifiers: Set<String> = [
      "com.apple.Terminal",
      "com.googlecode.iterm2",
      "dev.warp.Warp-Stable",
      "net.kovidgoyal.kitty",
      "org.alacritty",
      "io.alacritty",
      "com.github.wez.wezterm",
      "com.mitchellh.ghostty",
    ]

    /// `nil` or unrecognized -> `false` — the same "never assume a target is
    /// a terminal without a positive match" default the Linux registry
    /// uses, for the identical reason: guessing wrong would decline (or,
    /// worse, mis-chord) an ordinary app's snippet expansion.
    public static func isTerminal(bundleIdentifier: String?) -> Bool {
      guard let bundleIdentifier else { return false }
      return terminalBundleIdentifiers.contains(bundleIdentifier)
    }
  }
#endif
