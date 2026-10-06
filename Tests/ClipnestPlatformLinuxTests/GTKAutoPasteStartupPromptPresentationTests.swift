import Testing

@testable import ClipnestGTK

/// Routed follow-up ("proactively prompt for the auto-paste permission at
/// first run"): unit-tests the pure gating/text logic
/// (`AutoPasteStartupPromptPresentation`), separated from GTK widget code —
/// mirrors `GTKPermissionsTabPresentationTests`'s identical "pure logic
/// behind a GTK dialog, tested directly" split.
@Suite("AutoPasteStartupPromptPresentation")
struct GTKAutoPasteStartupPromptPresentationTests {
  @Test("Shows only when auto-paste is unavailable AND it has never been shown before")
  func shouldShowOnlyWhenClipboardOnlyAndNeverShown() {
    #expect(
      AutoPasteStartupPromptPresentation.shouldShow(
        isAutoPasteAvailable: false, hasShownBefore: false))
  }

  @Test("Never shows once auto-paste is available — the gating decision this task cared about")
  func neverShowsWhenAutoPasteAlreadyAvailable() {
    #expect(
      !AutoPasteStartupPromptPresentation.shouldShow(
        isAutoPasteAvailable: true, hasShownBefore: false))
    #expect(
      !AutoPasteStartupPromptPresentation.shouldShow(
        isAutoPasteAvailable: true, hasShownBefore: true))
  }

  @Test("Never shows twice — the 'never nag' contract")
  func neverShowsOnceAlreadyShown() {
    #expect(
      !AutoPasteStartupPromptPresentation.shouldShow(
        isAutoPasteAvailable: false, hasShownBefore: true))
  }

  @Test("The security explanation is reused verbatim from the Permissions tab, not restated")
  func securityExplanationIsSharedWithPermissionsTab() {
    #expect(
      AutoPasteStartupPromptPresentation.securityExplanationText
        == PermissionsTabPresentation.securityExplanationText)
    // Re-assert the property this shared text carries (see
    // `GTKPermissionsTabPresentationTests.securityExplanationNamesTheNarrowerGroup`)
    // so a future edit to either constant can't silently drop it.
    let text = AutoPasteStartupPromptPresentation.securityExplanationText
    #expect(text.contains("clipnest-input"))
    #expect(text.contains("broader \"input\" group"))
  }

  @Test("Explains what auto-paste unlocks and is honest that Clipnest still works without it")
  func explanationIsHonestAboutTheFallback() {
    let text = AutoPasteStartupPromptPresentation.explanationText
    #expect(text.contains("Ctrl+V"))
    #expect(text.contains("Clipnest works fine either way"))
  }

  @Test("States the logout/login requirement plainly, up front")
  func reloginTextIsStatedUpFront() {
    let text = AutoPasteStartupPromptPresentation.reloginText
    #expect(text.contains("log out"))
    #expect(text.contains("back in"))
  }

  @Test("Grant button label matches the Permissions tab's — same action, same wording")
  func grantButtonLabelMatchesPermissionsTab() {
    #expect(
      AutoPasteStartupPromptPresentation.grantButtonLabel
        == PermissionsTabPresentation.grantButtonLabel)
  }

  @Test("Succeeded status text carries the real outcome message plus the re-login reminder")
  func succeededStatusTextIncludesReloginReminder() {
    let text = AutoPasteStartupPromptPresentation.succeededStatusText(message: "Access granted.")
    #expect(text.contains("Access granted."))
    #expect(text.contains("Log out and back in"))
  }

  @Test("Failed status text carries the real failure reason plus a retry pointer")
  func failedStatusTextIncludesRetryPointer() {
    let text = AutoPasteStartupPromptPresentation.failedStatusText(message: "polkit denied.")
    #expect(text.contains("polkit denied."))
    #expect(text.contains("Settings"))
    #expect(text.contains("Permissions"))
  }
}
