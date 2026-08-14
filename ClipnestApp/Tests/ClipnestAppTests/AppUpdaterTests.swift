// AppUpdaterTests.swift
//
// `AppUpdater.runUpdate()` is a side effect (writes a temp file and opens
// Terminal via `NSWorkspace`) and is deliberately NOT exercised here — see
// `AppUpdater`'s doc comment. This suite covers the two pure, testable
// surfaces instead: `updateCommand` (the exact curl one-liner it shells out
// to) and `currentVersion` (the `Bundle.main` lookup).
//
// The `ClipnestApp` target's actual Swift module name is `Clipnest` — see
// `ItemKind+SFSymbolTests.swift`'s top doc comment for the full explanation.

import Testing

@testable import Clipnest

@Suite("AppUpdater")
struct AppUpdaterTests {

  @Test("updateCommand curls the public update.sh script and pipes it to bash")
  func updateCommandCurlsUpdateScriptIntoBash() {
    let command = AppUpdater.updateCommand

    #expect(
      command.contains(
        "https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh"))
    #expect(command.contains("curl"))
    #expect(command.contains("| bash"))
  }

  @Test("currentVersion is never empty")
  func currentVersionIsNonEmpty() {
    #expect(!AppUpdater.currentVersion.isEmpty)
  }
}
