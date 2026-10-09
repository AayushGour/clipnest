// GTKPickerWindowFooterVersionTests.swift
//
// Pins the pure text behind the picker footer's version button
// (`PickerWindow+Footer.swift`), matching macOS `PickerView`'s `v<version>`
// label and its "Check for updates" / "Update to vX available" tooltip.
import Testing

@testable import ClipnestGTK

@Suite("PickerWindow footer version")
struct GTKPickerWindowFooterVersionTests {
  @Test("version label is the version prefixed with v")
  func versionText() {
    #expect(PickerWindow.footerVersionText("1.2.0") == "v1.2.0")
  }

  @Test("no update: default tooltip")
  func tooltipWithoutUpdate() {
    #expect(
      PickerWindow.footerVersionTooltip(isUpdateAvailable: false, latestVersion: nil)
        == PickerWindow.footerVersionTooltipDefault)
    #expect(
      PickerWindow.footerVersionTooltip(isUpdateAvailable: false, latestVersion: "9.9.9")
        == PickerWindow.footerVersionTooltipDefault)
  }

  @Test("update available without a known version: default tooltip")
  func tooltipUpdateWithoutVersion() {
    #expect(
      PickerWindow.footerVersionTooltip(isUpdateAvailable: true, latestVersion: nil)
        == PickerWindow.footerVersionTooltipDefault)
  }

  @Test("update available: tooltip names the newer version")
  func tooltipWithUpdate() {
    #expect(
      PickerWindow.footerVersionTooltip(isUpdateAvailable: true, latestVersion: "1.3.0")
        .contains("v1.3.0"))
  }
}
