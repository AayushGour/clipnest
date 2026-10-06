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
///
/// `version`/`help` (T-BB2 fix): black-box testing on Ubuntu 22.04 found
/// `clipnest --version`/`--help` launched the full resident GUI (no
/// instance running — the tester had to `timeout`-kill it, exit 124) or
/// silently forwarded to a running instance and printed nothing (an
/// instance running). Neither flag was even recognized by `parse(_:)`
/// before this fix — both fell through to `.none`, the same as a plain
/// launch. `LinuxAppLifecycle.run(arguments:)` now checks for these two
/// FIRST, before any single-instance/bus logic and before GTK itself
/// initializes, so they always print and `exit(0)` with no window and no
/// forwarding, regardless of whether another instance owns the bus name.
public enum LinuxAppCLIFlag {
  public static let togglePicker = "--toggle-picker"
  public static let expandSnippet = "--expand-snippet"
  public static let version = "--version"
  public static let help = "--help"
}

public enum LinuxAppCLICommand: Equatable, Sendable {
  case togglePicker
  case expandSnippet
  case version
  case help
  case none
}

public enum LinuxAppCLI {
  /// Recognizes the FIRST matching flag in `arguments` — this binary is
  /// only ever launched with at most one of these at a time (a single
  /// keybinding invocation, or a single debugging/scripting invocation),
  /// so "first match wins" is simply "the match," with no ordering
  /// ambiguity to resolve.
  public static func parse(_ arguments: [String]) -> LinuxAppCLICommand {
    if arguments.contains(LinuxAppCLIFlag.togglePicker) { return .togglePicker }
    if arguments.contains(LinuxAppCLIFlag.expandSnippet) { return .expandSnippet }
    if arguments.contains(LinuxAppCLIFlag.version) { return .version }
    if arguments.contains(LinuxAppCLIFlag.help) { return .help }
    return .none
  }

  /// `--help`'s exact stdout text — real usage listing every flag
  /// `parse(_:)` above actually recognizes (T-BB2 fix: the man page
  /// documented flags that either did nothing or hung; this is the one
  /// place both `--help` and, going forward, the man page's OPTIONS
  /// section should match against). Flag tokens are interpolated from
  /// `LinuxAppCLIFlag` rather than re-typed, so this text can never drift
  /// from what `parse(_:)` actually matches.
  public static let usageText = """
    Usage: clipnest [OPTION]

    Options:
      \(LinuxAppCLIFlag.togglePicker)    Open or close the clipboard-history picker
      \(LinuxAppCLIFlag.expandSnippet)   Expand the current selection as a snippet keyword
      \(LinuxAppCLIFlag.version)              Print the installed version and exit
      \(LinuxAppCLIFlag.help)                 Show this help and exit

    With no options, clipnest runs as the resident background instance —
    the normal way it starts, via autostart, a global shortcut, or D-Bus
    activation. If an instance is already running, --toggle-picker and
    --expand-snippet are forwarded to it instead of starting a second one;
    --version and --help always run locally and exit immediately, whether
    or not an instance is already running.

    See clipnest-ctl(1) to control a running instance from the command
    line (open-settings, ping, and the same toggle-picker/expand-snippet/
    version commands above).
    """
}
