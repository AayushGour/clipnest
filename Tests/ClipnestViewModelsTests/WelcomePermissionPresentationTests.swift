// WelcomePermissionPresentationTests.swift

import Testing

@testable import ClipnestViewModels

@Suite("WelcomeAccessibilityPresentation")
struct WelcomeAccessibilityPresentationTests {
  @Test("state resolution from trust + whether the user pressed Allow")
  func resolve() {
    #expect(
      WelcomeAccessibilityPresentation.state(isGranted: true, hasPressedAllow: false) == .allowed)
    #expect(
      WelcomeAccessibilityPresentation.state(isGranted: true, hasPressedAllow: true) == .allowed)
    #expect(
      WelcomeAccessibilityPresentation.state(isGranted: false, hasPressedAllow: false)
        == .notAllowed)
    #expect(
      WelcomeAccessibilityPresentation.state(isGranted: false, hasPressedAllow: true)
        == .awaitingUser)
  }

  @Test("not allowed: Allow button with hint, no stale guidance until requested")
  func notAllowed() {
    let c = WelcomeAccessibilityPresentation.content(for: .notAllowed)
    #expect(c.statusText == "Not allowed yet")
    #expect(c.actionTitle == "Allow Accessibility…")
    #expect(c.actionHint == "Opens a system prompt")
    #expect(c.isComplete == false)
    #expect(c.staleGuidance == nil)
  }

  @Test("awaiting: points at System Settings, Open System Settings button, stale guidance shared")
  func awaiting() {
    let c = WelcomeAccessibilityPresentation.content(for: .awaitingUser)
    #expect(
      c.statusText
        == "Waiting for you to turn Clipnest on in System Settings → Privacy & Security → Accessibility."
    )
    #expect(c.actionTitle == "Open System Settings")
    #expect(c.actionHint == "Opens the Accessibility pane")
    #expect(c.staleGuidance == AccessibilityPermissionCopy.staleEntryRemedy)
    #expect(c.isComplete == false)
  }

  @Test("allowed: check, no action, complete, announcement")
  func allowed() {
    let c = WelcomeAccessibilityPresentation.content(for: .allowed)
    #expect(c.statusText == "Allowed")
    #expect(c.actionTitle == nil)
    #expect(c.isComplete == true)
    #expect(WelcomeAccessibilityPresentation.allowedAnnouncement == "Accessibility allowed")
  }
}

@Suite("WelcomeGnomeExtensionPresentation")
struct WelcomeGnomeExtensionPresentationTests {
  @Test("unsupportedDesktop hides the row and supplies the plain line")
  func unsupported() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .unsupportedDesktop)
    #expect(c.isRowHidden)
    #expect(
      c.plainLine
        == "Your desktop isn't GNOME, so the global hotkey and direct paste may be limited. Clipnest still works from the tray icon."
    )
  }

  @Test("active: on, check, complete, no action")
  func active() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .active)
    #expect(c.statusText == "Hotkey everywhere: on")
    #expect(c.showsCheck && c.isComplete && c.action == nil)
  }

  @Test("installedNeedsRelogin: exact headline, no button, counts as completed")
  func relogin() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .installedNeedsRelogin)
    #expect(c.statusText == "Log out once to finish setup")
    #expect(c.detail == "Clipnest added its GNOME extension. GNOME loads it at your next login.")
    #expect(c.action == nil && c.isComplete && c.needsRelogin)
  }

  @Test("disabledByUser: Turn On action")
  func disabled() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .disabledByUser)
    #expect(c.statusText == "The Clipnest GNOME extension is turned off.")
    #expect(c.action == .turnOn)
    #expect(c.action?.title == "Turn On")
    #expect(!c.isComplete)
  }

  @Test("userExtensionsDisabled: detail, no action")
  func userDisabled() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .userExtensionsDisabled)
    #expect(
      c.statusText
        == "GNOME extensions are turned off on this computer, so Clipnest can't add its extension.")
    #expect(c.detail == "Turn them on in the Extensions app, then reopen this window.")
    #expect(c.action == nil && !c.isComplete)
  }

  @Test("failed: reason, Try Again, tray fallback note")
  func failed() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .failed(reason: "no network"))
    #expect(c.statusText == "Couldn't set up the GNOME extension.")
    #expect(c.detail == "no network")
    #expect(c.action == .tryAgain)
    #expect(c.action?.title == "Try Again")
    #expect(c.fallbackNote == "Clipnest still works from the tray icon.")
    #expect(!c.isComplete)
  }

  @Test("checking is neutral: not complete, no action, row visible")
  func checking() {
    let c = WelcomeGnomeExtensionPresentation.content(for: .checking)
    #expect(!c.isRowHidden && !c.isComplete && c.action == nil)
  }

  @Test("hotkey-pending note applies to relogin, disabled, failed only")
  func pendingNote() {
    func pending(_ s: GnomeExtensionStatus) -> Bool {
      WelcomeGnomeExtensionPresentation.hotkeyIsPendingSetup(s)
    }
    #expect(pending(.installedNeedsRelogin))
    #expect(pending(.disabledByUser))
    #expect(pending(.failed(reason: "x")))
    #expect(!pending(.active))
    #expect(!pending(.unsupportedDesktop))
  }

  @Test("combined relogin line only when both sides need a log out")
  func combined() {
    #expect(
      WelcomeGnomeExtensionPresentation.combinedReloginLine(
        keyboardNeedsRelogin: true, extensionStatus: .installedNeedsRelogin)
        == "Log out and back in once to finish.")
    #expect(
      WelcomeGnomeExtensionPresentation.combinedReloginLine(
        keyboardNeedsRelogin: true, extensionStatus: .active) == nil)
    #expect(
      WelcomeGnomeExtensionPresentation.combinedReloginLine(
        keyboardNeedsRelogin: false, extensionStatus: .installedNeedsRelogin) == nil)
  }
}
