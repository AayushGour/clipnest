// WelcomeViewModelTests.swift
//
// T-WELCOME1: the platform-neutral step state machine + copy resolution.

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
      platform: platform, hotkey: hotkey ?? boundHotkey, isPermissionComplete: permissionComplete)
  }

  @Test("two steps, permission first then the merged hotkey/try step")
  func stepOrder() {
    #expect(WelcomeStep.allCases == [.permission, .tryIt])
    #expect(WelcomeStep.count == 2)
    #expect(WelcomeStep.permission.number == 1)
    #expect(WelcomeStep.tryIt.number == 2)
    #expect(WelcomeStep.tryIt.heading == "Try your hotkey")
    #expect(WelcomeCopy.subtitle == "Everything you copy is saved. Two quick steps to get started.")
  }

  @Test("starts on step 1 (permission) with step 2 upcoming")
  func initialState() {
    let vm = make()
    #expect(vm.activeStep == .permission)
    #expect(vm.state(of: .permission) == .current)
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
    #expect(vm.activeStep == .tryIt)
    #expect(vm.state(of: .permission) == .done)
  }

  @Test("Continue walks 1 -> 2; an ungranted permission reads skipped, not done")
  func continueWalk() {
    let vm = make()
    #expect(vm.continueTapped() == .advanced)
    #expect(vm.activeStep == .tryIt)
    #expect(vm.state(of: .permission) == .skipped)
    #expect(vm.primaryTitle == "Done")
  }

  @Test("Skip on step 1 marks it skipped and advances")
  func skipAdvances() {
    let vm = make()
    #expect(vm.skipTapped() == .advanced)
    #expect(vm.state(of: .permission) == .skipped)
    #expect(vm.activeStep == .tryIt)
  }

  @Test("Skip on step 2 closes and leaves it skipped")
  func skipOnTryItCloses() {
    let vm = make()
    _ = vm.continueTapped()
    #expect(vm.skipTapped() == .close)
    #expect(vm.state(of: .tryIt) == .skipped)
  }

  @Test("the last step's primary button is Done and closes")
  func doneOnLastStep() {
    let vm = make()
    _ = vm.continueTapped()
    #expect(vm.primaryTitle == "Done")
    #expect(vm.continueTapped() == .close)
  }

  @Test("permission completing while step 1 is active advances to step 2 and announces")
  func permissionCompletesOnStep1() {
    let vm = make()
    vm.updatePermission(isComplete: true, announcement: "Accessibility allowed")
    #expect(vm.state(of: .permission) == .done)
    #expect(vm.activeStep == .tryIt)
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
    _ = vm.continueTapped()
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
    _ = detected.continueTapped()
    detected.pickerDidShow()
    detected.tryItHintTimedOut()
    #expect(detected.showsTryItHint == false)
  }

  @Test("unbound hotkey: step 2 is skipped state, copy points at Settings + menu bar")
  func unbound() {
    let vm = make(hotkey: .unbound, permissionComplete: true)
    _ = vm.continueTapped()
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
    #expect(vm.permissionBodyText.contains("Ctrl+V"))
    #expect(make().permissionBodyText.contains("Cmd-V"))
  }

  @Test("accessibility labels read Step N of 2 with state")
  func accessibilityLabels() {
    let vm = make()
    #expect(
      vm.accessibilityLabel(for: .permission) == "Step 1 of 2: Paste straight into apps, current")
    #expect(vm.accessibilityLabel(for: .tryIt) == "Step 2 of 2: Try your hotkey, upcoming")
    _ = vm.skipTapped()
    #expect(
      vm.accessibilityLabel(for: .permission) == "Step 1 of 2: Paste straight into apps, skipped")
    #expect(vm.accessibilityLabel(for: .tryIt) == "Step 2 of 2: Try your hotkey, current")
  }

  @Test("collapsed rows state where they stand: already-granted shows Allowed")
  func collapsedAlreadyGranted() {
    let vm = make(permissionComplete: true)
    #expect(vm.collapsedStatusText(for: .permission) == nil)  // active row
    #expect(vm.collapsedStatusText(for: .tryIt) == "⌥⌘V")
    _ = vm.continueTapped()
    #expect(vm.collapsedStatusText(for: .permission) == "Allowed")
    #expect(vm.collapsedStatusText(for: .tryIt) == nil)  // active row
  }

  @Test("collapsed step 1 carries its skipped copy once the user moved on")
  func collapsedSkipped() {
    let vm = make()
    #expect(vm.collapsedStatusText(for: .tryIt) == "⌥⌘V")
    _ = vm.continueTapped()
    #expect(
      vm.collapsedStatusText(for: .permission)
        == "Not allowed - you can turn this on later in Settings → Permissions.")
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
    _ = vm.continueTapped()
    #expect(vm.collapsedStatusAccessibilityText(for: .permission) == "Allowed")
    let unbound = make(hotkey: .unbound)
    #expect(unbound.collapsedStatusAccessibilityText(for: .tryIt) == "No hotkey set")
  }

  // MARK: T-WELCOME4-LX — step 2 while the hotkey cannot work yet

  private var linuxHotkey: WelcomeHotkey { WelcomeHotkey.gnomeAccelerator("<Alt><Super>v") }

  @Test("pending setup: step 2 does not ask for a key press; points at the tray icon")
  func tryItPendingSetupCopy() {
    let vm = make(platform: .linux, hotkey: linuxHotkey, permissionComplete: true)
    _ = vm.continueTapped()
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
    _ = vm.continueTapped()
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
      isPermissionComplete: complete)
  }

  @Test("step 1 with the action button shown focuses the action; without it, the primary button")
  func stepOne() {
    let vm = make()
    #expect(vm.focusTarget(permissionActionAvailable: true) == .permissionAction)
    #expect(vm.focusTarget(permissionActionAvailable: false) == .primaryButton)
  }

  @Test("granting (step change) and moving to step 2 refocus the primary button")
  func afterStepChange() {
    let vm = make()
    vm.updatePermission(isComplete: true, announcement: nil)
    #expect(vm.activeStep == .tryIt)
    #expect(vm.focusTarget(permissionActionAvailable: true) == .primaryButton)
    #expect(make(complete: true).focusTarget(permissionActionAvailable: true) == .primaryButton)
  }
}
