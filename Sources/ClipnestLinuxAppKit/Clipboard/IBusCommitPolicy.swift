import Foundation

/// Per-app eligibility for snippet expansion's IBus commit tier
/// (T-IBUS-REPLACER, D-IBUS-1). Mirrors `TerminalAppRegistry`'s shape
/// (`Sources/ClipnestPlatformLinux/Input/TerminalAppRegistry.swift`) — a
/// `Set` of app identifiers kept in ONE place per coding-standards.md's
/// "no magic strings" rule, plus a direct predicate — but inverted: this is
/// an EXCLUDE list, not an include list, because the correct default is
/// eligible.
///
/// **Deliberately empty.** The Electron/Chromium POC
/// (`T-POC-IBUS-ELECTRON`, `.claude/task-board.md`) found no app class that
/// needs excluding — `commit_text`/`delete_surrounding_text` landed exact
/// on native Wayland, XWayland, and forced-native-Wayland-with-X11-available,
/// including under held modifiers. The VTE-terminal POC leg
/// (`T-IBUS-TIER2`) found the OPPOSITE of `TerminalAppRegistry`'s own
/// reason for existing: terminals are not excluded from this tier, they
/// are the case it is uniquely good at — `DeleteSurroundingText`/
/// `CommitText` operate on the terminal's own text buffer via a real
/// cursor-relative protocol, unlike the clipboard tier's copy/paste, which
/// has no delete step and is provably wrong there (`SelectionReplaceResult
/// .declinedTerminalTarget`'s doc comment). So `LinuxIBusSelectionReplacer`
/// never needs (and must never gain) a terminal-decline check of its own.
///
/// This registry exists as a SEAM, not a workaround for a known-bad case:
/// if a future app class is found (this POC's own open questions name
/// Electron/Chromium under native-Wayland Ozone, browser chrome, and a
/// third-party Electron app's own dialogs as unverified, not failed — see
/// `T-POC-IBUS-ELECTRON`), it is added here rather than invented
/// speculatively now. Inventing an entry with no measured failure would be
/// exactly the kind of un-evidenced guess this codebase's whole IBus
/// investigation has been built to avoid.
public enum IBusCommitPolicy {
  /// App identifiers (bundle/desktop-file/WM_CLASS style — whatever
  /// `FrontmostAppRef.bundleID` is populated with, the same source
  /// `TerminalAppRegistry` reads) excluded from the IBus commit tier.
  /// Empty — see this type's own top doc comment for why.
  public static let excludedIdentifiers: Set<String> = []

  /// Whether the IBus commit tier should even be ATTEMPTED for
  /// `identifier`. `nil`/unrecognized -> `true` (eligible): this stack
  /// never assumes a target is excluded without a positive match, the same
  /// never-guess-wrong-by-default convention `TerminalAppRegistry
  /// .isTerminal(appIdentifier:)` uses for the opposite polarity.
  public static func isEligible(appIdentifier identifier: String?) -> Bool {
    guard let identifier else { return true }
    return !excludedIdentifiers.contains(identifier)
  }
}
