import Foundation

/// The tiny CLI surface this binary recognizes when a hotkey-bound
/// invocation launches/messages it — the payload
/// `GSettingsCustomKeybinding.install(command:...)` (tier 4, the
/// universal floor) puts in a keybinding's `command=`, and the exact
/// argv `SingleInstance.forwardArguments`/`org.freedesktop.Application
/// .Open` carries to an already-running instance. Kept as ONE named
/// constant list + a pure parser (rather than re-spelled at each of
/// those three call sites) per `coding-standards.md`'s "no magic
/// strings" rule.
public enum LinuxAppCLIFlag {
  public static let togglePicker = "--toggle-picker"
  public static let expandSnippet = "--expand-snippet"
}

public enum LinuxAppCLICommand: Equatable, Sendable {
  case togglePicker
  case expandSnippet
  case none
}

public enum LinuxAppCLI {
  /// Recognizes the FIRST matching flag in `arguments` — this binary is
  /// only ever launched with at most one of these at a time (a single
  /// keybinding invocation), so "first match wins" is simply "the match,"
  /// with no ordering ambiguity to resolve.
  public static func parse(_ arguments: [String]) -> LinuxAppCLICommand {
    if arguments.contains(LinuxAppCLIFlag.togglePicker) { return .togglePicker }
    if arguments.contains(LinuxAppCLIFlag.expandSnippet) { return .expandSnippet }
    return .none
  }
}
