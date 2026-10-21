// WelcomeViewModelTests.swift
//
// T-WELCOME1: the platform-neutral step state machine + copy resolution.

import Foundation
import Testing

@testable import ClipnestViewModels

@MainActor
@Suite("WelcomeViewModel")
struct WelcomeViewModelTests {
  private let boundHotkey = WelcomeHotkey.macOS(
    command: true, option: true, control: false, shift: false, key: "V")

  private func make(
    platform: WelcomePlatform = .macOS, hotkey: WelcomeHotkey? = nil,
    permissionComplete: Bool = false
  ) -> WelcomeViewModel {
    WelcomeViewModel(
      platform: platform, hotkey: hotkey ?? boundHotkey, isPermissionComplete: permissionComplete,
      launchAtLogin: .inert)
  }

  /// Advances past the permission and open-at-login steps onto "Try your hotkey".
  private func toTryIt(_ vm: WelcomeViewModel) {
    leaveStepOne(vm)
    _ = vm.continueTapped()
  }

  /// Leaves step 1: Continue when granted, else "Set up later" + its confirmation.
  private func leaveStepOne(_ vm: WelcomeViewModel) {
    if vm.isPermissionComplete {
      _ = vm.continueTapped()
    } else {
      _ = vm.skipTapped()
      _ = vm.skipTapped()
    }
  }

  @Test("three steps: permission, open at login, then the merged hotkey/try step")
  func stepOrder() {
    #expect(WelcomeStep.allCases == [.permission, .openAtLogin, .tryIt, .logOut])
    #expect(make().steps == [.permission, .openAtLogin, .tryIt])
    #expect(WelcomeStep.count == 3)
    #expect(WelcomeStep.permission.number == 1)
    #expect(WelcomeStep.openAtLogin.number == 2)
    #expect(WelcomeStep.openAtLogin.heading == "Open Clipnest at login")
    #expect(WelcomeStep.tryIt.number == 3)
    #expect(WelcomeStep.tryIt.heading == "Try your hotkey")
    #expect(
      WelcomeCopy.subtitle == "Everything you copy is saved. Three quick steps to get started.")
  }

  @Test("starts on step 1 (permission) with step 2 upcoming")
  func initialState() {
    let vm = make()
    #expect(vm.activeStep == .permission)
    #expect(vm.state(of: .permission) == .current)
    #expect(vm.state(of: .openAtLogin) == .upcoming)
    #expect(vm.state(of: .tryIt) == .upcoming)
    #expect(vm.primaryTitle == "Continue")
    #expect(vm.initialFocus == .permissionAction)
  }

  @Test("already-granted permission still opens on step 1: Allowed, Continue focused")
  func allGrantedOpensOnStepOne() {
    let vm = make(permissionComplete: true)
    #expect(vm.activeStep == .permission)
    #expect(vm.state(of: .permission) == .done)
    #expect(vm.initialFocus == .primaryButton)
    #expect(vm.primaryTitle == "Continue")
    #expect(vm.continueTapped() == .advanced)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.state(of: .permission) == .done)
  }

  @Test("Continue walks 1 -> 2 -> 3; a postponed permission reads skipped, not done")
  func continueWalk() {
    let vm = make()
    leaveStepOne(vm)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.state(of: .permission) == .skipped)
    #expect(vm.primaryTitle == "Continue")
    #expect(vm.continueTapped() == .advanced)
    #expect(vm.activeStep == .tryIt)
    #expect(vm.primaryTitle == "Done")
  }

  @Test("Set up later on step 1 needs confirmation, then marks it skipped and advances")
  func skipAdvances() {
    let vm = make()
    #expect(vm.skipTapped() == .stayed)
    #expect(vm.activeStep == .permission)
    #expect(vm.skipTapped() == .advanced)
    #expect(vm.state(of: .permission) == .skipped)
    #expect(vm.activeStep == .openAtLogin)
  }

  @Test("Skip on step 2 closes and leaves it skipped")
  func skipOnTryItCloses() {
    let vm = make()
    toTryIt(vm)
    #expect(vm.skipTapped() == .close)
    #expect(vm.state(of: .tryIt) == .skipped)
  }

  @Test("the last step's primary button is Done and closes")
  func doneOnLastStep() {
    let vm = make()
    toTryIt(vm)
    #expect(vm.primaryTitle == "Done")
    #expect(vm.continueTapped() == .close)
  }

  @Test("permission completing while step 1 is active advances to step 2 and announces")
  func permissionCompletesOnStep1() {
    let vm = make()
    vm.updatePermission(isComplete: true, announcement: "Accessibility allowed")
    #expect(vm.state(of: .permission) == .done)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.announcement == "Accessibility allowed")
  }

  @Test("a repeat update with no change does not re-announce")
  func noReannounce() {
    let vm = make()
    vm.updatePermission(isComplete: true, announcement: "Accessibility allowed")
    vm.clearAnnouncement()
    vm.updatePermission(isComplete: true, announcement: "Accessibility allowed")
    #expect(vm.announcement == nil)
  }

  @Test("picker shown on step 2 flips it to success, primary stays Done, and announces")
  func pickerShown() {
    let vm = make()
    toTryIt(vm)
    vm.pickerDidShow()
    #expect(vm.hasDetectedHotkey)
    #expect(vm.state(of: .tryIt) == .done)
    #expect(vm.primaryTitle == "Done")
    #expect(vm.tryItStatusText == "It works. Press Esc to close the picker.")
    #expect(vm.announcement == "Hotkey detected. It works.")
  }

  @Test("detection is only active on step 2: a picker open during step 1 is ignored")
  func pickerShownOnStepOneIgnored() {
    let vm = make()
    vm.pickerDidShow()
    #expect(!vm.hasDetectedHotkey)
    #expect(vm.state(of: .tryIt) == .upcoming)
    #expect(vm.announcement == nil)
  }

  @Test("hint appears only after the timeout and only while undetected")
  func hint() {
    let vm = make(permissionComplete: true)
    #expect(vm.showsTryItHint == false)
    vm.tryItHintTimedOut()
    #expect(vm.showsTryItHint == true)
    let detected = make(permissionComplete: true)
    toTryIt(detected)
    detected.pickerDidShow()
    detected.tryItHintTimedOut()
    #expect(detected.showsTryItHint == false)
  }

  @Test("unbound hotkey: step 2 is skipped state, copy points at Settings + menu bar")
  func unbound() {
    let vm = make(hotkey: .unbound, permissionComplete: true)
    toTryIt(vm)
    #expect(vm.state(of: .tryIt) == .skipped)
    #expect(vm.primaryTitle == "Done")
    #expect(
      vm.tryItBodyText
        == "No hotkey is set. Choose one in Settings → Shortcuts, or click the Clipnest icon in the menu bar."
    )
    vm.pickerDidShow()
    #expect(vm.state(of: .tryIt) == .skipped)
    let linux = make(platform: .linux, hotkey: .unbound)
    #expect(linux.tryItBodyText.hasSuffix("or click the Clipnest icon in the tray."))
  }

  @Test("rebinding re-resolves copy and un-skips step 2")
  func rebind() {
    let vm = make(hotkey: .unbound)
    vm.updateHotkey(boundHotkey)
    #expect(vm.tryItBodyText.contains("⌥⌘V"))
    #expect(vm.state(of: .tryIt) == .upcoming)
  }

  @Test("bound copy interpolates the live hotkey")
  func boundCopy() {
    let vm = make()
    #expect(
      vm.tryItBodyText
        == "Copy any text, then press ⌥⌘V to open your clipboard history. Search, pick, and paste."
    )
    #expect(vm.tryItStatusText == "Waiting for the hotkey…")
  }

  @Test("Linux flavours of the platform-specific copy")
  func linuxCopy() {
    let vm = make(platform: .linux, hotkey: .gnomeAccelerator("<Alt><Super>v"))
    #expect(vm.tryItBodyText.contains("Alt + Super + V"))
    #expect(vm.tryItHintText.contains("tray icon, or finish step 1 first"))
    #expect(make(platform: .macOS).tryItHintText.contains("menu bar"))
    #expect(WelcomeCopy.setUpLaterConfirmation(platform: .linux).contains("Ctrl+V"))
    #expect(WelcomeCopy.setUpLaterConfirmation(platform: .macOS).contains("Cmd-V"))
  }

  @Test("accessibility labels read Step N of 3 with state")
  func accessibilityLabels() {
    let vm = make()
    #expect(
      vm.accessibilityLabel(for: .permission) == "Step 1 of 3: Paste straight into apps, current")
    #expect(
      vm.accessibilityLabel(for: .openAtLogin) == "Step 2 of 3: Open Clipnest at login, upcoming")
    #expect(vm.accessibilityLabel(for: .tryIt) == "Step 3 of 3: Try your hotkey, upcoming")
    leaveStepOne(vm)
    #expect(
      vm.accessibilityLabel(for: .permission) == "Step 1 of 3: Paste straight into apps, skipped")
    #expect(
      vm.accessibilityLabel(for: .openAtLogin) == "Step 2 of 3: Open Clipnest at login, current")
    _ = vm.skipTapped()
    #expect(vm.accessibilityLabel(for: .tryIt) == "Step 3 of 3: Try your hotkey, current")
  }

  @Test("collapsed rows state where they stand: already-granted shows Allowed")
  func collapsedAlreadyGranted() {
    let vm = make(permissionComplete: true)
    #expect(vm.collapsedStatusText(for: .permission) == nil)  // active row
    #expect(vm.collapsedStatusText(for: .tryIt) == "⌥⌘V")
    toTryIt(vm)
    #expect(vm.collapsedStatusText(for: .permission) == "Allowed")
    #expect(vm.collapsedStatusText(for: .tryIt) == nil)  // active row
  }

  @Test("collapsed step 1 carries its skipped copy once the user moved on")
  func collapsedSkipped() {
    let vm = make()
    #expect(vm.collapsedStatusText(for: .tryIt) == "⌥⌘V")
    leaveStepOne(vm)
    #expect(vm.collapsedStatusText(for: .permission) == WelcomeCopy.permissionSkippedStatus)
    #expect(WelcomeCopy.permissionSkippedStatus.contains("only copies it"))
  }

  @Test("collapsed step 2 reads the hotkey, or No hotkey set; never when active")
  func collapsedTryIt() {
    #expect(make(hotkey: .unbound).collapsedStatusText(for: .tryIt) == "No hotkey set")
    #expect(make().collapsedStatusText(for: .tryIt) == "⌥⌘V")
  }

  @Test("collapsed step 2 is spoken as words; other rows and unbound read as shown")
  func collapsedAccessibilityText() {
    let vm = make(permissionComplete: true)
    #expect(vm.collapsedStatusAccessibilityText(for: .tryIt) == vm.hotkey.spokenText)
    #expect(vm.collapsedStatusAccessibilityText(for: .tryIt) == "Option Command V")
    #expect(vm.collapsedStatusAccessibilityText(for: .permission) == nil)  // active row
    toTryIt(vm)
    #expect(vm.collapsedStatusAccessibilityText(for: .permission) == "Allowed")
    let unbound = make(hotkey: .unbound)
    #expect(unbound.collapsedStatusAccessibilityText(for: .tryIt) == "No hotkey set")
  }

  // MARK: T-WELCOME4-LX — step 2 while the hotkey cannot work yet

  private var linuxHotkey: WelcomeHotkey { WelcomeHotkey.gnomeAccelerator("<Alt><Super>v") }

  @Test("pending setup: step 2 does not ask for a key press; points at the tray icon")
  func tryItPendingSetupCopy() {
    let vm = make(platform: .linux, hotkey: linuxHotkey, permissionComplete: true)
    toTryIt(vm)
    vm.setHotkeyPendingSetup(
      WelcomeGnomeExtensionPresentation.hotkeyIsPendingSetup(.installedNeedsRelogin))
    #expect(vm.activeStep == .tryIt)
    #expect(!vm.tryItBodyText.contains("press Alt"))
    #expect(vm.tryItBodyText.contains("logged out and back in"))
    #expect(vm.tryItBodyText.contains("tray icon"))
    #expect(vm.tryItStatusText == WelcomeCopy.tryItWaitingForTray)
    #expect(vm.tryItHintText == "Nothing happening? Click the Clipnest tray icon.")
  }

  @Test("pending setup: opening the picker (tray) is still detected, with honest copy")
  func tryItPendingSetupDetection() {
    let vm = make(platform: .linux, hotkey: linuxHotkey, permissionComplete: true)
    toTryIt(vm)
    vm.setHotkeyPendingSetup(true)
    vm.pickerDidShow()
    #expect(vm.state(of: .tryIt) == .done)
    #expect(vm.tryItStatusText == WelcomeCopy.tryItSucceededViaTray)
    #expect(vm.announcement == WelcomeCopy.tryItOpenedAnnouncement)
  }

  @Test("not pending: step 2 copy is unchanged on Linux and macOS")
  func tryItNotPendingUnchanged() {
    let linux = make(platform: .linux, hotkey: linuxHotkey, permissionComplete: true)
    #expect(linux.tryItBodyText.hasPrefix("Copy any text, then press Alt + Super + V to open"))
    #expect(linux.tryItStatusText == WelcomeCopy.tryItWaiting)
    let mac = make(permissionComplete: true)
    #expect(mac.tryItBodyText.hasPrefix("Copy any text, then press ⌥⌘V to open"))
    #expect(mac.tryItHintText.contains("menu bar"))
  }
}

@MainActor
@Suite("WelcomeViewModel focus target (T-WELCOME5)")
struct WelcomeFocusTargetTests {
  private func make(complete: Bool = false) -> WelcomeViewModel {
    WelcomeViewModel(
      platform: .macOS,
      hotkey: .macOS(command: true, option: true, control: false, shift: false, key: "V"),
      isPermissionComplete: complete, launchAtLogin: .inert)
  }

  @Test("step 1 with the action button shown focuses the action; without it, the primary button")
  func stepOne() {
    let vm = make()
    #expect(vm.focusTarget(permissionActionAvailable: true) == .permissionAction)
    // Continue is disabled while something is missing, so it never takes focus;
    // "Set up later" is the only enabled control left.
    #expect(vm.focusTarget(permissionActionAvailable: false) == .secondaryButton)
    #expect(make(complete: true).focusTarget(permissionActionAvailable: false) == .primaryButton)
  }

  @Test("late action: opened on Set up later, the action arrives, user has not moved focus")
  func lateActionMovesFocus() {
    let vm = make()
    vm.focusApplied(vm.focusTarget(permissionActionAvailable: false))
    #expect(vm.lateFocusTarget(permissionActionAvailable: false) == nil)
    #expect(vm.lateFocusTarget(permissionActionAvailable: true) == .permissionAction)
    // Once applied, nothing further to do.
    vm.focusApplied(.permissionAction)
    #expect(vm.lateFocusTarget(permissionActionAvailable: true) == nil)
  }

  @Test("late action: never yanks focus after the user moved it")
  func lateActionRespectsUser() {
    let vm = make()
    vm.focusApplied(.secondaryButton)
    vm.userDidMoveFocus()
    #expect(vm.lateFocusTarget(permissionActionAvailable: true) == nil)
    // A fresh programmatic focus starts a new window.
    vm.focusApplied(.secondaryButton)
    #expect(vm.lateFocusTarget(permissionActionAvailable: true) == .permissionAction)
  }

  @Test("late action: only when focus started on the fallback button; confirming never")
  func lateActionOnlyFromFallback() {
    let vm = make()
    vm.focusApplied(.permissionAction)
    #expect(vm.lateFocusTarget(permissionActionAvailable: true) == nil)
    vm.focusApplied(.secondaryButton)
    _ = vm.skipTapped()
    #expect(vm.lateFocusTarget(permissionActionAvailable: true) == .primaryButton)
    let fresh = make()
    #expect(fresh.lateFocusTarget(permissionActionAvailable: true) == nil)
  }

  @Test("confirming Set up later focuses Go back; cancelling returns to the grant action")
  func confirming() {
    let vm = make()
    _ = vm.skipTapped()
    #expect(vm.focusTarget(permissionActionAvailable: true) == .primaryButton)
    _ = vm.continueTapped()
    #expect(vm.focusTarget(permissionActionAvailable: true) == .permissionAction)
  }

  @Test("granting (step change) refocuses the open-at-login switch; the last step the primary")
  func afterStepChange() {
    let vm = make()
    vm.updatePermission(isComplete: true, announcement: nil)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.focusTarget(permissionActionAvailable: true) == .launchAtLoginToggle)
    _ = vm.continueTapped()
    #expect(vm.activeStep == .tryIt)
    #expect(vm.focusTarget(permissionActionAvailable: true) == .primaryButton)
    #expect(make(complete: true).focusTarget(permissionActionAvailable: true) == .primaryButton)
  }
}

// MARK: - T-WELCOMELOGIN1: the "Open Clipnest at login" step

@MainActor
@Suite("WelcomeViewModel open at login (T-WELCOMELOGIN1)")
struct WelcomeOpenAtLoginTests {
  private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "not allowed here" }
  }

  /// In-memory stand-in for the shared backend (SMAppService / autostart file).
  @MainActor
  private final class Backend {
    var enabled: Bool
    var failWrites = false
    var writes: [Bool] = []
    var recorded = 0
    init(enabled: Bool = false) { self.enabled = enabled }

    var login: WelcomeLaunchAtLogin {
      WelcomeLaunchAtLogin(
        isEnabled: { self.enabled },
        setEnabled: { value in
          if self.failWrites { throw Boom() }
          self.writes.append(value)
          self.enabled = value
        },
        recordChoice: { self.recorded += 1 })
    }
  }

  private func make(_ backend: Backend, preChecked: Bool = true) -> WelcomeViewModel {
    let vm = WelcomeViewModel(
      platform: .macOS,
      hotkey: .macOS(command: true, option: true, control: false, shift: false, key: "V"),
      isPermissionComplete: true, launchAtLogin: backend.login, launchAtLoginPreChecked: preChecked)
    _ = vm.continueTapped()  // permission -> open at login
    return vm
  }

  @Test("starts pre-checked (recommended) with plain copy; nothing written until Continue")
  func preChecked() {
    let backend = Backend()
    let vm = make(backend)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.wantsLaunchAtLogin)
    #expect(
      vm.openAtLoginBodyText == "Start Clipnest when you log in so nothing you copy is missed.")
    #expect(backend.writes.isEmpty)
    #expect(vm.primaryTitle == "Continue")
  }

  @Test("Continue applies the choice through the shared backend, records it, and advances")
  func continueApplies() {
    let backend = Backend()
    let vm = make(backend)
    #expect(vm.continueTapped() == .advanced)
    #expect(backend.enabled)
    #expect(backend.writes == [true])
    #expect(backend.recorded == 1)
    #expect(vm.state(of: .openAtLogin) == .done)
    #expect(vm.activeStep == .tryIt)
    #expect(vm.collapsedStatusText(for: .openAtLogin) == "On")
    #expect(vm.announcement == "Clipnest will open at login")
  }

  @Test("already enabled and still checked: no redundant write, still recorded")
  func alreadyEnabled() {
    let backend = Backend(enabled: true)
    let vm = make(backend)
    #expect(vm.continueTapped() == .advanced)
    #expect(backend.writes.isEmpty)
    #expect(backend.recorded == 1)
  }

  @Test("unchecking then Continue turns the login item off and reads Off")
  func uncheckDisables() {
    let backend = Backend(enabled: true)
    let vm = make(backend)
    vm.setWantsLaunchAtLogin(false)
    #expect(vm.continueTapped() == .advanced)
    #expect(backend.enabled == false)
    #expect(vm.state(of: .openAtLogin) == .skipped)
    #expect(vm.collapsedStatusText(for: .openAtLogin) == "Off")
  }

  @Test("Skip leaves the system untouched but records that the user answered")
  func skipLeavesSystemAlone() {
    let backend = Backend()
    let vm = make(backend)
    #expect(vm.skipTapped() == .advanced)
    #expect(backend.writes.isEmpty)
    #expect(backend.recorded == 1)
    #expect(backend.enabled == false)
    #expect(vm.state(of: .openAtLogin) == .skipped)
    #expect(vm.activeStep == .tryIt)
  }

  @Test("a failed registration stays on the step, shows why, and reverts the switch to reality")
  func failureStays() {
    let backend = Backend()
    backend.failWrites = true
    let vm = make(backend)
    #expect(vm.continueTapped() == .stayed)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.launchAtLoginError == "not allowed here")
    #expect(vm.wantsLaunchAtLogin == false)
    #expect(backend.recorded == 0)
    // Continue again now means "leave it off": advances, error cleared.
    #expect(vm.continueTapped() == .advanced)
    #expect(vm.launchAtLoginError == nil)
  }

  @Test("toggling clears a stale error; focus lands on the switch while the step is active")
  func toggleClearsErrorAndFocus() {
    let backend = Backend()
    backend.failWrites = true
    let vm = make(backend)
    _ = vm.continueTapped()
    vm.setWantsLaunchAtLogin(true)
    #expect(vm.launchAtLoginError == nil)
    #expect(vm.focusTarget(permissionActionAvailable: false) == .launchAtLoginToggle)
  }

  @Test("the picker opening on the open-at-login step does not count as trying the hotkey")
  func pickerIgnoredOnLoginStep() {
    let vm = make(Backend())
    vm.pickerDidShow()
    #expect(!vm.hasDetectedHotkey)
  }

  @Test("macOS permission copy: hotkey needs no Accessibility; paste and expansion do")
  func accurateAccessibilityCopy() {
    let body = WelcomeCopy.permissionBody(platform: .macOS)
    #expect(body.contains("Your hotkey opens Clipnest without any permission"))
    #expect(body.contains("paste the item you pick straight into the app"))
    #expect(body.contains("expand snippets"))
    let later = WelcomeCopy.setUpLaterConfirmation(platform: .macOS)
    #expect(later.contains("only copies it"))
    #expect(later.contains("snippets will not expand"))
    #expect(later.contains("Your hotkey still opens the picker"))
  }
}

// MARK: - T-WELCOMEGRANT1: step 1 must be granted (or consciously postponed)

@MainActor
@Suite("WelcomeViewModel permission gating (T-WELCOMEGRANT1)")
struct WelcomePermissionGatingTests {
  private func make(
    platform: WelcomePlatform = .macOS, complete: Bool = false
  ) -> WelcomeViewModel {
    WelcomeViewModel(
      platform: platform,
      hotkey: .macOS(command: true, option: true, control: false, shift: false, key: "V"),
      isPermissionComplete: complete, launchAtLogin: .inert)
  }

  @Test("Continue is disabled and inert until everything is granted")
  func continueGated() {
    let vm = make()
    #expect(!vm.isPrimaryEnabled)
    #expect(vm.continueTapped() == .stayed)
    #expect(vm.activeStep == .permission)
    #expect(vm.state(of: .permission) == .current)
  }

  @Test("already granted: Continue enabled, no Set up later button")
  func grantedOpensEnabled() {
    let vm = make(complete: true)
    #expect(vm.isPrimaryEnabled)
    #expect(!vm.showsSecondary)
    #expect(vm.continueTapped() == .advanced)
    #expect(vm.state(of: .permission) == .done)
  }

  @Test("a grant mid-session completes step 1 and moves on, announcing it")
  func grantFlipsLive() {
    let vm = make(platform: .linux)
    vm.updatePermission(isComplete: true, announcement: "Paste setup finished.")
    #expect(vm.isPrimaryEnabled)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.announcement == "Paste setup finished.")
  }

  @Test("Set up later: first tap only asks, shows exactly what won't work, announces it")
  func setUpLaterNeedsConfirmation() {
    let vm = make()
    #expect(vm.secondaryTitle == "Set up later")
    #expect(vm.skipTapped() == .stayed)
    #expect(vm.isConfirmingSetUpLater)
    #expect(vm.activeStep == .permission)
    #expect(vm.state(of: .permission) == .current)
    #expect(vm.setUpLaterConfirmationText == WelcomeCopy.setUpLaterConfirmation(platform: .macOS))
    #expect(vm.announcement == vm.setUpLaterConfirmationText)
    #expect(vm.primaryTitle == "Go back")
    #expect(vm.secondaryTitle == "Set up later anyway")
    #expect(vm.isPrimaryEnabled)
  }

  @Test("Go back cancels the confirmation without leaving step 1")
  func goBack() {
    let vm = make()
    _ = vm.skipTapped()
    #expect(vm.continueTapped() == .stayed)
    #expect(!vm.isConfirmingSetUpLater)
    #expect(vm.setUpLaterConfirmationText == nil)
    #expect(vm.primaryTitle == "Continue")
    #expect(!vm.isPrimaryEnabled)
  }

  @Test("confirming Set up later moves on and marks step 1 skipped")
  func confirmMovesOn() {
    let vm = make()
    _ = vm.skipTapped()
    #expect(vm.skipTapped() == .advanced)
    #expect(vm.activeStep == .openAtLogin)
    #expect(vm.state(of: .permission) == .skipped)
    #expect(!vm.isConfirmingSetUpLater)
  }

  @Test("granting while the confirmation is open dismisses it")
  func grantDuringConfirmation() {
    let vm = make()
    _ = vm.skipTapped()
    vm.updatePermission(isComplete: true, announcement: nil)
    #expect(!vm.isConfirmingSetUpLater)
    #expect(vm.state(of: .permission) == .done)
  }

  @Test("Linux confirmation copy names Ctrl+V and makes no snippet claim")
  func linuxConfirmationCopy() {
    let text = WelcomeCopy.setUpLaterConfirmation(platform: .linux)
    #expect(text.contains("Ctrl+V"))
    #expect(!text.contains("snippets"))
  }

  @Test("steps 2 and 3 keep a plain Skip")
  func laterStepsKeepSkip() {
    let vm = make(complete: true)
    _ = vm.continueTapped()
    #expect(vm.secondaryTitle == "Skip")
    #expect(vm.showsSecondary)
    #expect(vm.isPrimaryEnabled)
    #expect(vm.setUpLaterConfirmationText == nil)
  }

  @Test("step 1 is never described as optional")
  func notOptional() {
    #expect(
      make().accessibilityLabel(for: .permission)
        == "Step 1 of 3: Paste straight into apps, current")
    #expect(!WelcomeCopy.permissionBody(platform: .macOS).lowercased().contains("optional"))
    #expect(!WelcomeCopy.permissionBody(platform: .linux).lowercased().contains("optional"))
  }
}

// MARK: - T-WELCOMEGRANT1: Linux log-out step replaces "Try your hotkey" when a re-login is pending

@MainActor
@Suite("WelcomeViewModel log-out step (T-WELCOMEGRANT1)")
struct WelcomeLogOutStepTests {
  private func make(canLogOut: Bool = true, relogin: Bool = true) -> WelcomeViewModel {
    let vm = WelcomeViewModel(
      platform: .linux, hotkey: .gnomeAccelerator("<Alt><Super>v"), isPermissionComplete: true,
      launchAtLogin: .inert, canLogOut: canLogOut)
    vm.setNeedsRelogin(relogin)
    return vm
  }

  private func toLastStep(_ vm: WelcomeViewModel) {
    _ = vm.continueTapped()
    _ = vm.continueTapped()
  }

  @Test("re-login needed: the last step is Log out, still step 3 of 3, Try-it is off the list")
  func sequenceWithRelogin() {
    let vm = make()
    #expect(vm.steps == [.permission, .openAtLogin, .logOut])
    toLastStep(vm)
    #expect(vm.activeStep == .logOut)
    #expect(WelcomeStep.logOut.number == 3)
    #expect(
      vm.accessibilityLabel(for: .logOut) == "Step 3 of 3: Log out to finish setup, current")
    #expect(vm.focusTarget(permissionActionAvailable: false) == .primaryButton)
  }

  @Test("no re-login: the last step stays Try your hotkey")
  func sequenceWithoutRelogin() {
    let vm = make(relogin: false)
    #expect(vm.steps == [.permission, .openAtLogin, .tryIt])
    toLastStep(vm)
    #expect(vm.activeStep == .tryIt)
    #expect(vm.primaryTitle == "Done")
  }

  @Test("Log Out Now asks the platform to log out and stays on the step until it answers")
  func logOutNow() {
    let vm = make()
    toLastStep(vm)
    #expect(vm.primaryTitle == "Log Out Now")
    #expect(vm.continueTapped() == .logOut)
    #expect(vm.activeStep == .logOut)
  }

  @Test("log-out request accepted: the window closes and the step counts as done")
  func logOutSucceededCloses() {
    let vm = make()
    toLastStep(vm)
    #expect(vm.continueTapped() == .logOut)
    #expect(vm.logOutFinished(succeeded: true) == .close)
    #expect(vm.logOutError == nil)
    #expect(vm.state(of: .logOut) == .done)
  }

  @Test("log-out request failed: stays open with the error; a retry that works clears it")
  func logOutFailedStays() {
    let vm = make()
    toLastStep(vm)
    #expect(vm.continueTapped() == .logOut)
    #expect(vm.logOutFinished(succeeded: false) == .stayed)
    #expect(vm.logOutError == WelcomeCopy.logOutFailed)
    #expect(vm.announcement == WelcomeCopy.logOutFailed)
    #expect(vm.activeStep == .logOut)
    #expect(vm.logOutFinished(succeeded: true) == .close)
    #expect(vm.logOutError == nil)
  }

  @Test("Later closes, remembers it as skipped, and the body says what waits for the next login")
  func later() {
    let vm = make()
    toLastStep(vm)
    #expect(vm.secondaryTitle == "Later")
    #expect(vm.showsSecondary)
    #expect(vm.logOutBodyText.contains("only copies it"))
    #expect(vm.logOutBodyText.contains("Choose Later"))
    #expect(vm.skipTapped() == .close)
    #expect(vm.state(of: .logOut) == .skipped)
  }

  @Test("no log-out API (non-GNOME): instructions only, Done closes, no secondary")
  func noLogOutApi() {
    let vm = make(canLogOut: false)
    toLastStep(vm)
    #expect(vm.primaryTitle == "Done")
    #expect(!vm.showsSecondary)
    #expect(vm.logOutBodyText.contains("desktop's menu"))
    #expect(!vm.logOutBodyText.contains("Choose Later"))
    #expect(vm.continueTapped() == .close)
  }

  @Test("a re-login that becomes pending while on the last step swaps it in place")
  func swapsInPlace() {
    let vm = make(relogin: false)
    toLastStep(vm)
    #expect(vm.activeStep == .tryIt)
    vm.setNeedsRelogin(true)
    #expect(vm.activeStep == .logOut)
    vm.setNeedsRelogin(false)
    #expect(vm.activeStep == .tryIt)
  }

  @Test("a pending re-login while still on step 1 does not move the user")
  func staysOnEarlierSteps() {
    let vm = WelcomeViewModel(
      platform: .linux, hotkey: .unbound, isPermissionComplete: false, launchAtLogin: .inert)
    vm.setNeedsRelogin(true)
    #expect(vm.activeStep == .permission)
  }

  @Test("macOS never gets a log-out step")
  func macNeverLogsOut() {
    let vm = WelcomeViewModel(
      platform: .macOS, hotkey: .unbound, isPermissionComplete: true, launchAtLogin: .inert)
    #expect(vm.steps.last == .tryIt)
  }

  @Test("collapsed Log out row states where it stands")
  func collapsed() {
    let vm = make()
    #expect(vm.collapsedStatusText(for: .logOut) == WelcomeCopy.logOutNeededStatus)
  }
}
