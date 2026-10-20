// AppUpdater.swift
//
// Self-update, triggered by clicking the version label in
// `PickerView.shortcutHintBar`. This type makes **no network calls itself**
// (no `URLSession`, no sockets) — it shells out, via Terminal, to the public
// `scripts/update.sh` (see that script's own top doc comment for the update
// flow: download + checksum-verify the release `.dmg`, verify the new app's
// code signature matches the installed one, stage-then-swap, relaunch). No
// clipboard/user data is sent; the only network traffic is the script
// downloading a public GitHub release, entirely outside this process.
//
// Security (T-AUD-UPDPIN): the script is fetched from the release TAG being
// installed (`.../<vX.Y.Z>/scripts/update.sh`), NOT the mutable `main`
// branch, and the same tag is handed to it via `CLIPNEST_VERSION`. The tag is
// strictly validated (`UpdateCommand.validatedTag`) before it reaches any URL
// or command line; with no valid tag we open the releases page instead and
// never fall back to `main`. The command builder lives in
// `ClipnestViewModels/System/UpdateCommand.swift` (SwiftPM-testable).
//
// `runUpdate()` writes a throwaway `.command` file and hands it to
// `NSWorkspace.shared.open(_:)` rather than launching `Process`/`Task`
// directly — an `open`ed executable `.command` file runs in Terminal
// without requiring the Automation/AppleEvents permission a direct
// `NSAppleScript`/`Process`-into-Terminal approach would need, and Terminal
// runs it as an independent process that survives Clipnest quitting (the
// script itself quits and relaunches Clipnest — see `scripts/update.sh`).

import AppKit
import ClipnestViewModels
import Foundation

enum AppUpdater {
  /// The running app's version (`CFBundleShortVersionString`, e.g.
  /// `"0.5.0"`), shown in `PickerView.shortcutHintBar` as `v0.5.0`.
  static var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
  }

  /// The Terminal one-liner pinned to `latestVersion` (`"1.4.1"` or
  /// `"v1.4.1"`), or `nil` if it isn't a strict `vX.Y.Z` tag. Factored out
  /// (and delegated to the pure `UpdateCommand`) so it's unit-testable
  /// without shelling out.
  static func updateCommand(forVersion latestVersion: String?) -> String? {
    UpdateCommand.command(forTag: latestVersion)
  }

  /// Writes the pinned update command to a throwaway executable `.command` file in the
  /// temp directory and opens it — macOS runs `.command` files in Terminal.
  /// Falls back to opening the GitHub releases page in the default browser
  /// if `latestVersion` isn't a valid tag or writing/opening the script fails for any reason (e.g. an unwritable
  /// temp directory), so the user always has a path to updating manually.
  static func runUpdate(latestVersion: String?) {
    guard let command = updateCommand(forVersion: latestVersion) else {
      openReleasesPage()
      return
    }
    let script = "#!/bin/bash\n\(command)"
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipnest-update-\(UUID().uuidString)")
      .appendingPathExtension("command")

    do {
      try script.write(to: scriptURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
      NSWorkspace.shared.open(scriptURL)
    } catch {
      openReleasesPage()
    }
  }

  private static func openReleasesPage() {
    if let releasesURL = URL(string: "https://github.com/AayushGour/clipnest/releases") {
      NSWorkspace.shared.open(releasesURL)
    }
  }
}
