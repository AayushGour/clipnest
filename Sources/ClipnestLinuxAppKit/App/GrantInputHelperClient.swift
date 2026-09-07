import ClipnestGTK
import Foundation

/// T-OPT3: the ONE call site that invokes the existing, already-scoped
/// privileged helper (`packaging/linux/scripts/clipnest-grant-input`) via
/// `pkexec`, gated by the `app.clipnest.grant-input` polkit action (see
/// `packaging/linux/polkit/app.clipnest.grant-input.policy`, whose
/// `org.freedesktop.policykit.exec.path` annotation binds that action to
/// this exact helper path). This client does not widen that policy, does
/// not add a second privileged path, and never itself runs anything as
/// root — the only privileged step is `pkexec` authenticating the user and
/// executing the one helper the policy already names by exact path.
public enum GrantInputHelperClient {
  /// Matches the helper's real install path (`debian/rules`'s `dh_install`
  /// line for `packaging/linux/scripts/clipnest-grant-input`, and that
  /// script's own top doc comment: "installed to
  /// /usr/libexec/clipnest/clipnest-grant-input"). Named here as the one
  /// Swift-side reference to it (coding-standards.md: no magic strings).
  public static let helperPath = "/usr/libexec/clipnest/clipnest-grant-input"

  /// `pkexec` itself — a standard, fixed system path on every distribution
  /// this package targets (it's a hard `Depends:` in `debian/control`).
  public static let pkexecExecutablePath = "/usr/bin/pkexec"

  /// Pure — the exact argument list `requestGrant(completion:)` invokes
  /// `pkexec` with, factored out so it's unit-testable without spawning a
  /// process, mirroring `UpdateChecker.curlArguments(for:)`'s identical
  /// "pure argument construction, unit-tested; the real `Process` spawn is
  /// integration-verified separately" split. `pkexec <helperPath>` with no
  /// further arguments: `clipnest-grant-input` itself takes none — the
  /// identity of "who to grant" comes only from `$PKEXEC_UID`, which
  /// `pkexec` sets itself (see that script's own security-note doc
  /// comment for why passing a username as an argument here would be
  /// exactly the mistake it's designed to be immune to).
  public static func pkexecArguments(helperPath: String = helperPath) -> [String] {
    [helperPath]
  }

  private static let processQueue = DispatchQueue(
    label: "com.clipnest.grantinputhelperclient.processQueue", qos: .userInitiated)

  /// Runs `pkexec clipnest-grant-input` on a background queue — `pkexec`
  /// blocks until a polkit authentication agent answers its dialog, or
  /// fails fast if none is registered (this project's own container
  /// verification: no session/system authentication agent in a headless
  /// test container, so this path fails immediately rather than hanging) —
  /// and reports the outcome via `completion`, called on `processQueue`,
  /// NOT necessarily the GTK/main thread. `SettingsWindow
  /// +Permissions.swift` hops back to the GTK thread itself
  /// (`Task { @MainActor in ... }`, pumped by `GTKMainActorBridge`) before
  /// touching any widget — mirrors `UpdateChecker.fetchLatestReleaseJSON()`'s
  /// identical off-main-thread `Process` pattern (same reason: a blocking
  /// `Process.run()`/`waitUntilExit()` must never run on the GTK thread).
  ///
  /// `pkexec`'s own exit codes (per `pkexec(1)`): 0 success, 1 the helper
  /// itself failed, 2 the user dismissed/cancelled the authentication
  /// dialog, 3 polkit denied the request (not authorized), 127 `pkexec`
  /// itself could not be found or run. This client does not give each of
  /// those its own bespoke message — `pkexec`'s/the helper's own captured
  /// stderr text is already the more specific, correct explanation in
  /// every case; the exit code only decides success vs. failure.
  public static func requestGrant(completion: @escaping @Sendable (UInputGrantOutcome) -> Void) {
    processQueue.async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: pkexecExecutablePath)
      process.arguments = pkexecArguments()
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr

      do {
        try process.run()
      } catch {
        completion(
          .failed(
            message: "Could not run pkexec (\(error.localizedDescription)). "
              + "Is polkit installed?"))
        return
      }

      let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
      let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      let outputText = decodedTrimmed(outputData)
      let errorText = decodedTrimmed(errorData)

      if process.terminationStatus == 0 {
        completion(.succeeded(message: outputText.isEmpty ? "Access granted." : outputText))
      } else {
        let reason =
          errorText.isEmpty
          ? "pkexec exited with status \(process.terminationStatus)."
          : errorText
        completion(.failed(message: reason))
      }
    }
  }

  private static func decodedTrimmed(_ data: Data) -> String {
    (String(data: data, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
