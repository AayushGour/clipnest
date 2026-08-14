// AppUpdater.swift
//
// Self-update, triggered by clicking the version label in
// `PickerView.shortcutHintBar`. Per coding-standards.md's "Local-only,
// always" privacy must (no `URLSession`, no sockets anywhere in the
// codebase), this type makes **no network calls itself** — it shells out,
// via Terminal, to the exact same public `scripts/update.sh` curl one-liner
// a user could already run by hand (see that script's own top doc comment
// for the update flow: check the latest GitHub release, download+install
// the `.dmg`, relaunch). No clipboard/user data is sent; the only network
// traffic is the script downloading a public GitHub release, which happens
// entirely outside this process.
//
// `runUpdate()` writes a throwaway `.command` file and hands it to
// `NSWorkspace.shared.open(_:)` rather than launching `Process`/`Task`
// directly — an `open`ed executable `.command` file runs in Terminal
// without requiring the Automation/AppleEvents permission a direct
// `NSAppleScript`/`Process`-into-Terminal approach would need, and Terminal
// runs it as an independent process that survives Clipnest quitting (the
// script itself quits and relaunches Clipnest — see `scripts/update.sh`).

import AppKit
import Foundation

enum AppUpdater {
  /// The running app's version (`CFBundleShortVersionString`, e.g.
  /// `"0.5.0"`), shown in `PickerView.shortcutHintBar` as `v0.5.0`.
  static var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
  }

  /// The public, versionless URL to `scripts/update.sh` on `main` — same
  /// script + same URL documented in that script's own "Usage" doc comment,
  /// so there is exactly one place this URL is defined.
  private static let updateScriptURL =
    "https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh"

  /// The one-liner run by `runUpdate()`, factored out as its own property so
  /// it's unit-testable without actually shelling out (`runUpdate()` itself
  /// is a side effect — opens Terminal — and isn't called from tests).
  static var updateCommand: String {
    "curl -fsSL \(updateScriptURL) | bash"
  }

  /// Writes `updateCommand` to a throwaway executable `.command` file in the
  /// temp directory and opens it — macOS runs `.command` files in Terminal.
  /// Falls back to opening the GitHub releases page in the default browser
  /// if writing/opening the script fails for any reason (e.g. an unwritable
  /// temp directory), so the user always has a path to updating manually.
  static func runUpdate() {
    let script = "#!/bin/bash\n\(updateCommand)"
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipnest-update-\(UUID().uuidString)")
      .appendingPathExtension("command")

    do {
      try script.write(to: scriptURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
      NSWorkspace.shared.open(scriptURL)
    } catch {
      if let releasesURL = URL(string: "https://github.com/AayushGour/clipnest/releases") {
        NSWorkspace.shared.open(releasesURL)
      }
    }
  }
}
