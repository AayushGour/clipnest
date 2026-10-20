// AppUpdaterTests.swift
//
// `AppUpdater.runUpdate()` is a side effect (writes a temp file and opens
// Terminal via `NSWorkspace`) and is deliberately NOT exercised here — see
// `AppUpdater`'s doc comment. This suite covers the two pure, testable
// surfaces instead: `updateCommand(forVersion:)` (the exact curl one-liner it
// shells out to; validation itself is covered by `UpdateCommandTests`) and `currentVersion` (the `Bundle.main` lookup).
//
// The `ClipnestApp` target's actual Swift module name is `Clipnest` — see
// `ItemKind+SFSymbolTests.swift`'s top doc comment for the full explanation.

import Testing

@testable import Clipnest

@Suite("AppUpdater")
struct AppUpdaterTests {

  @Test("updateCommand pins update.sh to the release tag, never main")
  func updateCommandIsPinnedToTag() {
    let command = AppUpdater.updateCommand(forVersion: "1.4.1")

    #expect(
      command?.contains(
        "https://raw.githubusercontent.com/AayushGour/clipnest/v1.4.1/scripts/update.sh") == true)
    #expect(command?.contains("/main/") == false)
    #expect(command?.contains("--proto '=https'") == true)
    #expect(command?.contains("| CLIPNEST_VERSION=v1.4.1 bash") == true)
  }

  @Test("updateCommand refuses an invalid tag instead of falling back to main")
  func updateCommandRejectsInvalidTag() {
    #expect(AppUpdater.updateCommand(forVersion: nil) == nil)
    #expect(AppUpdater.updateCommand(forVersion: "1.4.1; rm -rf ~") == nil)
  }

  @Test("currentVersion is never empty")
  func currentVersionIsNonEmpty() {
    #expect(!AppUpdater.currentVersion.isEmpty)
  }
}
