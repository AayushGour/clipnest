import Testing

@testable import ClipnestGTK

/// T-LXUPD: unit-tests the pure update-section decision logic
/// (`UpdateSettingsPresentation`), separated from GTK widget code — mirrors
/// `GTKPermissionsTabPresentationTests`'s identical "pure logic behind a
/// GTK tab, tested directly" split.
@Suite("UpdateSettingsPresentation")
struct GTKUpdateSettingsPresentationTests {
  @Test("versionLine shows the installed version")
  func versionLineShowsInstalledVersion() {
    #expect(UpdateSettingsPresentation.versionLine(installedVersion: "0.9.1") == "Clipnest v0.9.1")
  }

  @Test("updateAvailableLine names the latest version")
  func updateAvailableLineNamesLatestVersion() {
    #expect(
      UpdateSettingsPresentation.updateAvailableLine(latestVersion: "0.10.0")
        == "Update to v0.10.0 available")
  }

  @Test("explanation for .packageManaged names the real origin, not a generic 'a repository'")
  func packageManagedExplanationNamesTheOrigin() {
    let text = UpdateSettingsPresentation.explanation(
      for: .packageManaged(origin: "http://ppa.launchpad.net/x/clipnest/ubuntu jammy/main"),
      latestVersion: "0.10.0")
    #expect(text.contains("http://ppa.launchpad.net/x/clipnest/ubuntu jammy/main"))
    #expect(text.contains("apt"))
    #expect(text.contains("v0.10.0"))
  }

  @Test("explanation for .standaloneDebInstall says Clipnest can install it itself")
  func standaloneExplanationOffersInAppInstall() {
    let text = UpdateSettingsPresentation.explanation(
      for: .standaloneDebInstall, latestVersion: "0.10.0")
    #expect(text.lowercased().contains("clipnest can install"))
  }

  @Test("explanation for .undetermined surfaces the real reason and points at the releases page")
  func undeterminedExplanationSurfacesReasonAndReleasesPage() {
    let text = UpdateSettingsPresentation.explanation(
      for: .undetermined(reason: "apt-cache policy could not be run"), latestVersion: "0.10.0")
    #expect(text.contains("apt-cache policy could not be run"))
    #expect(text.contains(UpdateSettingsPresentation.releasesPageURL))
  }

  @Test("statusText(for step:) names every step distinctly")
  func stepStatusTextIsDistinctPerStep() {
    let steps: [LinuxUpdateStep] = [
      .checkingLatestRelease, .downloadingUpdate, .verifyingChecksum, .installing,
    ]
    let texts = Set(steps.map { UpdateSettingsPresentation.statusText(for: $0) })
    #expect(texts.count == steps.count)
  }

  @Test("statusText(for outcome:) reports a successful install with its version")
  func successOutcomeReportsVersion() {
    let text = UpdateSettingsPresentation.statusText(for: .succeeded(installedVersion: "0.10.0"))
    #expect(text.contains("0.10.0"))
  }

  @Test("statusText(for outcome:) never installs on a checksum mismatch — the message says so")
  func checksumMismatchOutcomeRefusesToInstall() {
    let text = UpdateSettingsPresentation.statusText(for: .failed(.checksumMismatch))
    #expect(text.lowercased().contains("checksum"))
    #expect(text.lowercased().contains("refusing"))
  }

  @Test("statusText(for outcome:) never installs when no checksum was published")
  func noChecksumPublishedOutcomeRefusesToInstall() {
    let text = UpdateSettingsPresentation.statusText(for: .failed(.noChecksumPublished))
    #expect(text.lowercased().contains("checksum"))
    #expect(text.lowercased().contains("refusing"))
  }

  @Test("statusText(for outcome:) reports up to date plainly")
  func upToDateOutcomeIsPlain() {
    #expect(UpdateSettingsPresentation.statusText(for: .upToDate) == "Already up to date.")
  }

  @Test("message(for: .installationCancelled) reads as authentication, not a generic failure")
  func installationCancelledMessageReadsAsAuthentication() {
    let message = UpdateSettingsPresentation.message(for: .installationCancelled)
    #expect(message.contains("authentication"))
  }

  @Test("message(for: .installationFailed) surfaces the real captured message verbatim")
  func installationFailedMessageIsVerbatim() {
    let message = UpdateSettingsPresentation.message(
      for: .installationFailed("dpkg: dependency problems prevent configuration"))
    #expect(message == "dpkg: dependency problems prevent configuration")
  }

  @Test("confirmInstallMessage names the version and mentions authentication")
  func confirmInstallMessageNamesVersionAndAuthentication() {
    let message = UpdateSettingsPresentation.confirmInstallMessage(latestVersion: "0.10.0")
    #expect(message.contains("0.10.0"))
    #expect(message.lowercased().contains("authenticate"))
  }
}
