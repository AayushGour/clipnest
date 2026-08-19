// UpdateCheckerTests.swift
//
// `UpdateChecker.checkNow()`'s actual `Process` spawn (curl against GitHub)
// is a real side effect — network I/O — and is deliberately NOT exercised
// here, same precedent as `AppUpdaterTests`' treatment of
// `AppUpdater.runUpdate()`. For the same reason, `start(settings:)` and
// `settingChanged(enabled: true)` are also not called with an
// "automatically check for updates" enabled `SettingsStore`: both can
// schedule an immediate `checkNow()` (see `UpdateChecker.scheduleTimer()`'s
// doc comment — a never-checked instance is always "due"), which would spawn
// the same real curl process from a test run. This suite instead covers the
// pure, testable surfaces: the tag-parsing/version-comparison helpers
// `checkNow()` itself is built from, and the instance's default/idle state.
//
// The `ClipnestApp` target's actual Swift module name is `Clipnest` — see
// `ItemKind+SFSymbolTests.swift`'s top doc comment for the full explanation.

import Foundation
import Testing

@testable import Clipnest

@Suite("UpdateChecker")
struct UpdateCheckerTests {

  // MARK: - isUpdateAvailable(installed:latestTag:)

  @Test("equal versions: no update available")
  func equalVersionsMeansNoUpdate() {
    #expect(!UpdateChecker.isUpdateAvailable(installed: "1.2.3", latestTag: "1.2.3"))
  }

  @Test("different versions: update available")
  func differentVersionsMeansUpdateAvailable() {
    #expect(UpdateChecker.isUpdateAvailable(installed: "1.2.3", latestTag: "1.2.4"))
  }

  @Test("v-prefixed tag compares equal to the same bare installed version")
  func vPrefixedTagNormalizesBeforeComparing() {
    #expect(!UpdateChecker.isUpdateAvailable(installed: "1.2.3", latestTag: "v1.2.3"))
  }

  @Test("v-prefixed tag with a genuinely newer version still reports available")
  func vPrefixedNewerTagReportsAvailable() {
    #expect(UpdateChecker.isUpdateAvailable(installed: "1.2.3", latestTag: "v1.3.0"))
  }

  // MARK: - normalizedVersion(fromTag:)

  @Test("strips a leading v")
  func normalizedVersionStripsLeadingV() {
    #expect(UpdateChecker.normalizedVersion(fromTag: "v0.6.0") == "0.6.0")
  }

  @Test("passes through a tag with no leading v unchanged")
  func normalizedVersionPassesThroughBareTag() {
    #expect(UpdateChecker.normalizedVersion(fromTag: "0.6.0") == "0.6.0")
  }

  // MARK: - parseTagName(fromReleaseJSON:)

  @Test("parses tag_name out of a real GitHub Releases API shape")
  func parsesTagNameFromRealisticJSON() {
    let json = """
      {"tag_name": "v0.7.0", "name": "Clipnest 0.7.0", "draft": false}
      """
    let data = Data(json.utf8)
    #expect(UpdateChecker.parseTagName(fromReleaseJSON: data) == "v0.7.0")
  }

  @Test("parses a tag_name with no v prefix")
  func parsesBareTagName() {
    let data = Data(#"{"tag_name": "0.7.0"}"#.utf8)
    #expect(UpdateChecker.parseTagName(fromReleaseJSON: data) == "0.7.0")
  }

  @Test("malformed JSON (not even valid JSON) returns nil")
  func malformedJSONReturnsNil() {
    let data = Data("not json at all {{{".utf8)
    #expect(UpdateChecker.parseTagName(fromReleaseJSON: data) == nil)
  }

  @Test("valid JSON missing tag_name returns nil")
  func validJSONMissingTagNameReturnsNil() {
    let data = Data(#"{"name": "Clipnest 0.7.0"}"#.utf8)
    #expect(UpdateChecker.parseTagName(fromReleaseJSON: data) == nil)
  }

  @Test("valid JSON with tag_name as the wrong type returns nil")
  func tagNameWrongTypeReturnsNil() {
    let data = Data(#"{"tag_name": 123}"#.utf8)
    #expect(UpdateChecker.parseTagName(fromReleaseJSON: data) == nil)
  }

  @Test("empty data returns nil")
  func emptyDataReturnsNil() {
    #expect(UpdateChecker.parseTagName(fromReleaseJSON: Data()) == nil)
  }

  // MARK: - Instance state (no `start`/`checkNow` — see this file's top doc comment)

  @MainActor
  @Test("a freshly constructed checker reports no update and nil version")
  func freshInstanceHasNoUpdate() {
    let checker = UpdateChecker(defaults: Self.makeDefaults())
    #expect(!checker.isUpdateAvailable)
    #expect(checker.latestVersion == nil)
  }

  @MainActor
  @Test("stop() is safe to call before start()")
  func stopBeforeStartIsSafe() {
    let checker = UpdateChecker(defaults: Self.makeDefaults())
    checker.stop()
    #expect(!checker.isUpdateAvailable)
  }

  @MainActor
  @Test("settingChanged(enabled: false) before start() is safe and schedules nothing")
  func settingChangedDisableBeforeStartIsSafe() {
    let checker = UpdateChecker(defaults: Self.makeDefaults())
    checker.settingChanged(enabled: false)
    #expect(!checker.isUpdateAvailable)
  }

  @MainActor
  @Test("start() with the setting disabled schedules nothing (no checkNow() side effect)")
  func startWithSettingDisabledDoesNothing() {
    let settings = SettingsStore(defaults: Self.makeDefaults())
    settings.automaticallyCheckForUpdates = false
    let checker = UpdateChecker(defaults: Self.makeDefaults())

    checker.start(settings: settings)

    #expect(!checker.isUpdateAvailable)
    #expect(checker.latestVersion == nil)
  }

  /// A throwaway, isolated `UserDefaults` suite so tests never touch the
  /// real app domain or each other — same helper shape as
  /// `SettingsStoreTests.makeDefaults()`.
  private static func makeDefaults() -> UserDefaults {
    let name = "UpdateCheckerTests-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
  }
}
