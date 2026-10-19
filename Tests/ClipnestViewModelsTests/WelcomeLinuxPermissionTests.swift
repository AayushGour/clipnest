import Testing

@testable import ClipnestViewModels

@Suite("WelcomeLinuxPermission (T-WELCOME1-LX)")
struct WelcomeLinuxPermissionTests {
  private func keyboard(_ state: WelcomeKeyboardAccess.State) -> WelcomeKeyboardAccess {
    WelcomeKeyboardAccess(state: state)
  }

  @Test("Initial state maps availability / group membership")
  func initialState() {
    #expect(
      WelcomeKeyboardAccess(isAutoPasteAvailable: true, isAlreadyInInputGroup: false).state
        == .allowed)
    #expect(
      WelcomeKeyboardAccess(isAutoPasteAvailable: false, isAlreadyInInputGroup: true).state
        == .pendingRelogin)
    #expect(
      WelcomeKeyboardAccess(isAutoPasteAvailable: false, isAlreadyInInputGroup: false).state
        == .available)
  }

  @Test("Grant flow: available -> inFlight (button disabled) -> succeeded; counts as complete")
  func grantSuccess() {
    var access = keyboard(.available)
    #expect(access.buttonTitle == LinuxInputPermissionCopy.grantButtonLabel)
    #expect(access.showsUpFrontNotes)
    let started = access.grantStarted()
    #expect(started)
    #expect(access.statusText == LinuxInputPermissionCopy.grantInFlightStatusText)
    #expect(!access.isButtonEnabled)
    let startedAgain = access.grantStarted()
    #expect(!startedAgain, "a second press while in flight is ignored")
    access.grantFinished(succeeded: true, message: "Done.")
    #expect(access.statusText == "Done. Log out and back in to start using it.")
    #expect(access.isComplete && access.needsRelogin && access.buttonTitle == nil)
  }

  @Test("Failure re-enables the button as Try Again, and a retry can start")
  func grantFailureThenRetry() {
    var access = keyboard(.available)
    access.grantStarted()
    access.grantFinished(succeeded: false, message: "polkit denied.")
    #expect(access.statusText?.contains("Couldn't grant access: polkit denied.") == true)
    #expect(access.statusText?.contains("Settings → Permissions") == true)
    #expect(access.buttonTitle == "Try Again" && access.isButtonEnabled && !access.isComplete)
    let retried = access.grantStarted()
    #expect(retried)
  }

  @Test("A stale completion cannot rewrite a settled state")
  func staleCompletionIgnored() {
    var access = keyboard(.allowed)
    access.grantFinished(succeeded: false, message: "late")
    #expect(access.state == .allowed)
  }

  @Test("Step 2 completes when the keyboard row is settled and the extension row settled or hidden")
  func completion() {
    let checking = WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .checking)
    #expect(!checking.isComplete)
    let active = WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .active)
    #expect(active.isComplete)
    #expect(
      WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .installedNeedsRelogin)
        .isComplete)
    #expect(
      WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .unsupportedDesktop)
        .isComplete)
    #expect(
      !WelcomeLinuxPermission(keyboard: keyboard(.available), extensionStatus: .active).isComplete)
    #expect(
      !WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .failed(reason: "x"))
        .isComplete)
  }

  @Test("Combined log-out line only when both sub-rows need a log-out")
  func combinedLine() {
    let both = WelcomeLinuxPermission(
      keyboard: keyboard(.succeeded(message: "ok")), extensionStatus: .installedNeedsRelogin)
    #expect(both.combinedReloginLine == "Log out and back in once to finish.")
    #expect(
      WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .installedNeedsRelogin)
        .combinedReloginLine == nil)
  }

  @Test("Hotkey pending-setup follows the extension status")
  func hotkeyPending() {
    #expect(
      WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .disabledByUser)
        .isHotkeyPendingSetup)
    #expect(
      !WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .active)
        .isHotkeyPendingSetup)
  }

  @Test("Collapsed summary keeps a pending log-out visible, else says Done / skipped copy")
  func collapsedSummary() {
    let relogin = WelcomeLinuxPermission(
      keyboard: keyboard(.allowed), extensionStatus: .installedNeedsRelogin)
    #expect(relogin.collapsedSummary(isSkipped: false) == "Log out once to finish setup")
    let done = WelcomeLinuxPermission(keyboard: keyboard(.allowed), extensionStatus: .active)
    #expect(done.collapsedSummary(isSkipped: false) == "Done")
    let skipped = WelcomeLinuxPermission(keyboard: keyboard(.available), extensionStatus: .active)
    #expect(skipped.collapsedSummary(isSkipped: true) == WelcomeCopy.permissionSkippedStatus)
  }
}

@Suite("LinuxInputPermissionCopy (shared by Settings tab + welcome)")
struct LinuxInputPermissionCopyTests {
  @Test("Security explanation names the narrower group and /dev/uinput")
  func security() {
    let text = LinuxInputPermissionCopy.securityExplanationText
    #expect(text.contains("clipnest-input"))
    #expect(text.contains("broader \"input\" group"))
    #expect(text.contains("/dev/uinput"))
  }

  @Test("Relogin note is stated up front")
  func relogin() {
    #expect(LinuxInputPermissionCopy.reloginText.contains("log out"))
    #expect(LinuxInputPermissionCopy.reloginText.contains("back in"))
  }

  @Test("Succeeded/failed texts carry the message")
  func outcomes() {
    let succeeded = LinuxInputPermissionCopy.succeededStatusText(message: "A.")
    #expect(succeeded.contains("Log out and back in"))
    #expect(LinuxInputPermissionCopy.failedStatusText(message: "B.").contains("B."))
  }

  @Test("pkexec 126/127 map to friendly copy; other failures keep the raw detail")
  func pkexecFailureMapping() {
    let raw =
      "Error executing command as another user: Not authorized\nThis incident has been reported."
    for status in [Int32(126), Int32(127)] {
      let text = LinuxInputPermissionCopy.failureMessage(exitStatus: status, rawDetail: raw)
      #expect(text == LinuxInputPermissionCopy.authorizationUnavailableText)
      #expect(!text.contains("incident"))
      #expect(text.contains("pkexec /usr/libexec/clipnest/clipnest-grant-input"))
    }
    let helperFailure = LinuxInputPermissionCopy.failureMessage(
      exitStatus: 1, rawDetail: "helper broke")
    #expect(helperFailure == "helper broke")
    let silent = LinuxInputPermissionCopy.failureMessage(exitStatus: 1, rawDetail: "")
    #expect(silent == "pkexec exited with status 1.")
  }

  @Test("Welcome and Settings share the failure wording")
  func sharedFailureWording() {
    let message = LinuxInputPermissionCopy.authorizationUnavailableText
    #expect(
      LinuxInputPermissionCopy.failedStatusText(message: message).hasPrefix(
        LinuxInputPermissionCopy.failedPrefixText(message: message)))
  }
}
