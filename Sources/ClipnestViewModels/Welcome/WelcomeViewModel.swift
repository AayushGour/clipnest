// WelcomeViewModel.swift
//
// T-WELCOME1: the platform-neutral state machine behind the first-run welcome
// window (design.md "Welcome window"). No AppKit/SwiftUI/GTK: each platform
// renders `state(of:)` + the copy accessors, forwards button taps to
// `continueTapped()` / `skipTapped()`, and feeds live facts in through
// `updateHotkey`, `updatePermission`, `pickerDidShow`, `tryItHintTimedOut`
// and (Linux) `setHotkeyPendingSetup`. Timers, polling and the actual
// permission/extension work stay in the platform layer (step 1 is
// platform-specific content; this type only needs to know whether it is
// complete).

import ClipnestCore
import Foundation

#if canImport(Combine)
  import Combine
#else
  import ClipnestObservation
#endif

public enum WelcomeStep: Int, CaseIterable, Sendable {
  case permission = 1
  /// Step 2: "Open Clipnest at login" (T-WELCOMELOGIN1): a pre-checked switch,
  /// applied when the user continues, so capture survives a reboot.
  case openAtLogin = 2
  /// Step 3: "Try your hotkey" (shows the hotkey, then detects it being used).
  case tryIt = 3
  /// Linux only (T-WELCOMEGRANT1): replaces `.tryIt` as the LAST step while a
  /// log-out is still needed (keyboard-access group or GNOME extension just set
  /// up), because the hotkey and direct paste cannot work before the next login.
  /// Shown as "Step 3 of 3" - the two last steps are never both on the list.
  case logOut = 4

  public var number: Int { self == .logOut ? WelcomeStep.tryIt.rawValue : rawValue }
  /// Steps the user sees (`tryIt` and `logOut` share the last slot).
  public static var count: Int { tryIt.rawValue }

  public var heading: String {
    switch self {
    case .permission: return WelcomeCopy.permissionHeading
    case .openAtLogin: return WelcomeCopy.openAtLoginHeading
    case .tryIt: return WelcomeCopy.tryItHeading
    case .logOut: return WelcomeCopy.logOutHeading
    }
  }
}

/// Where keyboard focus belongs (the secondary button only as a last resort).
public enum WelcomeInitialFocus: Equatable, Sendable {
  /// The step's own action (macOS "Allow Accessibility…") - permission missing.
  case permissionAction
  /// The footer primary button (Continue) - permission already granted.
  case primaryButton
  /// The "Open Clipnest at login" switch, while that step is active.
  case launchAtLoginToggle
  /// The low-emphasis footer button ("Set up later") - step 1 while permission
  /// is missing but the step's own action is not shown and Continue is disabled.
  case secondaryButton
}

public enum WelcomeStepState: Equatable, Sendable {
  case upcoming, current, done, skipped

  /// The state word VoiceOver/Orca read.
  fileprivate var spoken: String {
    switch self {
    case .upcoming: return "upcoming"
    case .current: return "current"
    case .done: return "done"
    case .skipped: return "skipped"
    }
  }
}

/// What the window should do after a button tap.
public enum WelcomeNavigation: Equatable, Sendable {
  case advanced
  case close
  /// The step could not be completed (launch-at-login registration failed):
  /// stay put; `launchAtLoginError` says why.
  case stayed
  /// The log-out step's primary button: the platform asks the session manager to
  /// log out (with its own confirmation), then reports back through
  /// `logOutFinished(succeeded:)`, which says whether to close the window.
  case logOut
}

/// The system boundary behind step 2, injected so the VM stays platform-free.
/// macOS: `LaunchAtLoginController` (SMAppService); Linux: the autostart
/// `.desktop` file. Both are the SAME state Settings -> General edits, so the
/// welcome switch and the Settings switch can never disagree.
@MainActor
public struct WelcomeLaunchAtLogin {
  public var isEnabled: @MainActor () -> Bool
  public var setEnabled: @MainActor (Bool) throws -> Void
  /// Called once the user's answer is in effect (feeds
  /// `SettingsStore.hasChosenLaunchAtLogin`).
  public var recordChoice: @MainActor () -> Void

  public init(
    isEnabled: @escaping @MainActor () -> Bool,
    setEnabled: @escaping @MainActor (Bool) throws -> Void,
    recordChoice: @escaping @MainActor () -> Void
  ) {
    self.isEnabled = isEnabled
    self.setEnabled = setEnabled
    self.recordChoice = recordChoice
  }

  /// No backing store (tests only): reads off, writes and choices drop. Always
  /// passed explicitly; production seams must wire the real backend.
  public static let inert = WelcomeLaunchAtLogin(
    isEnabled: { false }, setEnabled: { _ in }, recordChoice: {})
}

@MainActor
public final class WelcomeViewModel: ObservableObject {
  // Linux: the stand-in `ObservableObject` has no synthesized publisher
  // (see PickerViewModel / ClipnestObservation); Combine synthesizes it on Apple.
  #if !canImport(Combine)
    public let objectWillChange = ObservableObjectPublisher()
  #endif

  public let platform: WelcomePlatform
  /// Linux: the desktop offers a session-manager log-out API (GNOME). When false
  /// the log-out step only gives instructions.
  public let canLogOut: Bool

  @Published public private(set) var activeStep: WelcomeStep
  @Published public private(set) var hotkey: WelcomeHotkey
  @Published public private(set) var isPermissionComplete: Bool
  @Published public private(set) var hasDetectedHotkey = false
  @Published public private(set) var showsTryItHint = false
  /// Latest transition for a polite live region ("Accessibility allowed",
  /// "Hotkey detected. It works."). Only set on transitions, never on poll
  /// ticks. Platforms read it, announce it, then `clearAnnouncement()`.
  @Published public private(set) var announcement: String?
  @Published public private(set) var isHotkeyPendingSetup = false
  /// Step 2's switch. Applied to the system only when the user continues.
  @Published public private(set) var wantsLaunchAtLogin: Bool
  @Published public private(set) var launchAtLoginError: String?
  /// T-WELCOMEGRANT1: the user pressed "Set up later" on step 1 and is looking
  /// at what will not work. Cleared by Go back, by a grant, or by confirming.
  @Published public private(set) var isConfirmingSetUpLater = false
  /// Linux: a log-out is still needed (pending re-login), so the last step is
  /// `.logOut` instead of `.tryIt`. Always false on macOS.
  @Published public private(set) var needsRelogin = false
  /// Linux: why the last "Log Out Now" request failed; `nil` otherwise.
  @Published public private(set) var logOutError: String?

  private let launchAtLogin: WelcomeLaunchAtLogin
  private var outcomes: [WelcomeStep: WelcomeStepState] = [:]
  /// Focus bookkeeping (not published: the platform reads it, never renders it).
  private var appliedFocus: WelcomeInitialFocus?
  private var userMovedFocus = false

  /// - Parameter launchAtLoginPreChecked: the switch's starting value. Platforms
  ///   pass `true` (recommended) until the user has chosen once, then the real
  ///   system state, so reopening "Getting Started…" never re-enables a
  ///   login item the user turned off in Settings. Both Continue and Skip on
  ///   the open-at-login step call `launchAtLogin.recordChoice` (Skip leaves the
  ///   login state itself untouched), so "until the user has chosen" means
  ///   "has answered that step either way".
  public init(
    platform: WelcomePlatform, hotkey: WelcomeHotkey, isPermissionComplete: Bool,
    launchAtLogin: WelcomeLaunchAtLogin, launchAtLoginPreChecked: Bool = true,
    canLogOut: Bool = false
  ) {
    self.canLogOut = canLogOut
    self.launchAtLogin = launchAtLogin
    wantsLaunchAtLogin = launchAtLoginPreChecked
    self.platform = platform
    self.hotkey = hotkey
    self.isPermissionComplete = isPermissionComplete
    // Always starts on the permission step; an already-granted one reads
    // "Allowed" with Continue focused (`initialFocus`).
    activeStep = .permission
  }

  /// The last step: "Log out to finish setup" while a re-login is pending,
  /// else "Try your hotkey".
  public var finalStep: WelcomeStep { needsRelogin ? .logOut : .tryIt }

  /// The steps on the list, in order (platforms hide the other last-step row).
  public var steps: [WelcomeStep] { [.permission, .openAtLogin, finalStep] }

  public var initialFocus: WelcomeInitialFocus {
    isPermissionComplete ? .primaryButton : .permissionAction
  }

  /// Where focus belongs NOW, given whether the platform currently shows step
  /// 1's action button. Platforms re-apply it when the active step changes or
  /// the button disappears, so focus never lands on nothing (or on Skip).
  public func focusTarget(permissionActionAvailable: Bool) -> WelcomeInitialFocus {
    switch activeStep {
    case .permission:
      // Confirming: the (enabled) "Go back" button. Otherwise the grant action
      // while something is missing; the primary button only once it can act
      // (a disabled Continue cannot take focus).
      if isConfirmingSetUpLater { return .primaryButton }
      if isPermissionComplete { return .primaryButton }
      // Action hidden (e.g. extension still checking) and Continue disabled:
      // "Set up later" is the only enabled control left.
      return permissionActionAvailable ? .permissionAction : .secondaryButton
    case .openAtLogin: return .launchAtLoginToggle
    case .tryIt, .logOut: return .primaryButton
    }
  }

  /// The platform put focus on `target` itself (initial focus, a step change).
  /// This starts a fresh "has the user moved focus since?" window.
  public func focusApplied(_ target: WelcomeInitialFocus) {
    appliedFocus = target
    userMovedFocus = false
  }

  /// Focus moved for a reason the platform did not cause (Tab, a click).
  public func userDidMoveFocus() { userMovedFocus = true }

  /// A better focus target that became available AFTER focus was applied: the
  /// window opened on the fallback "Set up later" (step 1's action was still
  /// being checked) and the action has since appeared. `nil` = leave focus
  /// alone, including whenever the user moved it themselves.
  public func lateFocusTarget(permissionActionAvailable: Bool) -> WelcomeInitialFocus? {
    guard !userMovedFocus, appliedFocus == .secondaryButton else { return nil }
    let target = focusTarget(permissionActionAvailable: permissionActionAvailable)
    return target == .secondaryButton ? nil : target
  }

  // MARK: State

  public func state(of step: WelcomeStep) -> WelcomeStepState {
    switch step {
    case .permission where isPermissionComplete:
      return .done
    case .tryIt where hasDetectedHotkey && hotkey.isBound:
      return .done
    case .tryIt where !hotkey.isBound:
      return .skipped
    default:
      break
    }
    if let outcome = outcomes[step] { return outcome }
    return step == activeStep ? .current : .upcoming
  }

  public var primaryTitle: String {
    if isConfirmingSetUpLater { return WelcomeCopy.goBackTitle }
    if activeStep == .logOut {
      return canLogOut ? WelcomeCopy.logOutNowTitle : WelcomeCopy.doneTitle
    }
    return activeStep == finalStep ? WelcomeCopy.doneTitle : WelcomeCopy.continueTitle
  }

  /// T-WELCOMEGRANT1: Continue stays disabled on step 1 until every required
  /// permission is settled (`isPermissionComplete`); "Go back" is always live.
  public var isPrimaryEnabled: Bool {
    isConfirmingSetUpLater || activeStep != .permission || isPermissionComplete
  }

  /// The low-emphasis footer button: "Skip" on steps 2-3; on step 1 the
  /// escape hatch "Set up later" (then "Set up later anyway" while confirming).
  public var secondaryTitle: String {
    if activeStep == .logOut { return WelcomeCopy.logOutLaterTitle }
    guard activeStep == .permission else { return WelcomeCopy.skipTitle }
    return isConfirmingSetUpLater ? WelcomeCopy.setUpLaterConfirmTitle : WelcomeCopy.setUpLaterTitle
  }

  /// Hidden on step 1 once everything is granted (nothing left to postpone).
  public var showsSecondary: Bool {
    switch activeStep {
    case .permission: return !isPermissionComplete
    case .logOut: return canLogOut
    case .openAtLogin, .tryIt: return true
    }
  }

  /// What would not work, shown only while confirming.
  public var setUpLaterConfirmationText: String? {
    isConfirmingSetUpLater ? WelcomeCopy.setUpLaterConfirmation(platform: platform) : nil
  }

  public func accessibilityLabel(for step: WelcomeStep) -> String {
    let state = state(of: step)
    return WelcomeCopy.stepAccessibilityLabel(
      number: step.number, count: WelcomeStep.count, heading: step.heading, state: state.spoken)
  }

  // MARK: Copy

  public var permissionBodyText: String { WelcomeCopy.permissionBody(platform: platform) }

  public var openAtLoginBodyText: String { WelcomeCopy.openAtLoginBody }

  public var logOutBodyText: String { WelcomeCopy.logOutBody(canLogOut: canLogOut) }

  public var tryItBodyText: String {
    WelcomeCopy.tryItBody(
      hotkey: hotkey.displayText, platform: platform, hotkeyPendingSetup: isHotkeyPendingSetup)
  }

  public var tryItStatusText: String {
    switch (hasDetectedHotkey, isHotkeyPendingSetup) {
    case (true, true): return WelcomeCopy.tryItSucceededViaTray
    case (true, false): return WelcomeCopy.tryItSucceeded
    case (false, true): return WelcomeCopy.tryItWaitingForTray
    case (false, false): return WelcomeCopy.tryItWaiting
    }
  }

  public var tryItHintText: String {
    WelcomeCopy.tryItHint(platform: platform, hotkeyPendingSetup: isHotkeyPendingSetup)
  }

  /// One-line status shown on a row that is NOT the active step, so a
  /// collapsed row still says where it stands (e.g. "Allowed" for an
  /// already-granted step 1). `nil` for the active row, whose detail view
  /// carries its own status.
  public func collapsedStatusText(for step: WelcomeStep) -> String? {
    // Keyed on the ACTIVE step, not `.current` state: step 3 stays expanded
    // after success ("It works. Press Esc…") even though its state is `.done`.
    guard step != activeStep else { return nil }
    let state = state(of: step)
    switch step {
    case .permission:
      switch state {
      case .done: return WelcomeCopy.permissionAllowedStatus
      case .skipped: return WelcomeCopy.permissionSkippedStatus
      case .upcoming, .current: return WelcomeCopy.permissionNotAllowedYetStatus
      }
    case .openAtLogin:
      return wantsLaunchAtLogin ? WelcomeCopy.openAtLoginOnStatus : WelcomeCopy.openAtLoginOffStatus
    case .tryIt:
      if state == .done { return WelcomeCopy.tryItWorksShort }
      return hotkey.displayText ?? WelcomeCopy.noHotkeyShort
    case .logOut:
      return state == .skipped ? WelcomeCopy.logOutLaterStatus : WelcomeCopy.logOutNeededStatus
    }
  }

  /// Spoken form of `collapsedStatusText(for:)`: the hotkey step reads it as
  /// words ("Option Command V") instead of glyphs; everything else (and an
  /// unbound hotkey) reads exactly as shown. `nil` when nothing is shown.
  public func collapsedStatusAccessibilityText(for step: WelcomeStep) -> String? {
    guard let visible = collapsedStatusText(for: step) else { return nil }
    guard step == .tryIt, state(of: step) != .done else { return visible }
    return hotkey.spokenText ?? visible
  }

  // MARK: Buttons

  /// Primary button (Return). Advances; on the last step (try your hotkey) there is nothing
  /// further, so it closes (marking it skipped if unfinished). On step 2 it
  /// first applies the login-item choice. On step 1 it does nothing until
  /// everything is granted (`isPrimaryEnabled`); while confirming "Set up
  /// later" it is "Go back".
  public func continueTapped() -> WelcomeNavigation {
    if isConfirmingSetUpLater {
      isConfirmingSetUpLater = false
      return .stayed
    }
    switch activeStep {
    case .permission:
      guard isPermissionComplete else { return .stayed }
      outcomes[.permission] = .done
      return advance()
    case .openAtLogin:
      return applyLaunchAtLogin()
    case .tryIt:
      return closeFromTryIt()
    case .logOut:
      return canLogOut ? .logOut : .close
    }
  }

  /// The low-emphasis footer button. Steps 2-3: skips the step (the last one
  /// closes). Step 1 ("Set up later"): the first tap only asks for confirmation
  /// (`setUpLaterConfirmationText`), the second ("Set up later anyway") moves
  /// on, so the step cannot be skipped by accident but never traps the user.
  public func skipTapped() -> WelcomeNavigation {
    if activeStep == .permission && !isPermissionComplete && !isConfirmingSetUpLater {
      isConfirmingSetUpLater = true
      announcement = WelcomeCopy.setUpLaterConfirmation(platform: platform)
      return .stayed
    }
    switch activeStep {
    case .permission, .openAtLogin:
      isConfirmingSetUpLater = false
      // Skipping step 2 leaves the system untouched (nothing is applied) but
      // still counts as an answer, so the next Getting Started shows reality.
      if activeStep == .openAtLogin { launchAtLogin.recordChoice() }
      outcomes[activeStep] = .skipped
      return advance()
    case .tryIt:
      return closeFromTryIt()
    case .logOut:
      // "Later": the body already told the user what waits for the next login.
      outcomes[.logOut] = .skipped
      return .close
    }
  }

  /// The platform's answer to a `.logOut` navigation. The request went out
  /// (the desktop shows its own confirmation): this welcome is finished, close
  /// it. It failed: stay open with `logOutError` so the user can retry or log
  /// out from the desktop's menu.
  public func logOutFinished(succeeded: Bool) -> WelcomeNavigation {
    guard succeeded else {
      logOutError = WelcomeCopy.logOutFailed
      announcement = WelcomeCopy.logOutFailed
      return .stayed
    }
    logOutError = nil
    outcomes[.logOut] = .done
    return .close
  }

  private func advance() -> WelcomeNavigation {
    guard let index = steps.firstIndex(of: activeStep), index + 1 < steps.count else {
      return .close
    }
    activeStep = steps[index + 1]
    return .advanced
  }

  /// Step 2's Continue: write the choice through the shared backend. A failure
  /// (e.g. macOS refuses to register an app outside /Applications) keeps the
  /// user on the step with the reason and the switch reverted to reality, so it
  /// never claims something the system did not do.
  private func applyLaunchAtLogin() -> WelcomeNavigation {
    if wantsLaunchAtLogin != launchAtLogin.isEnabled() {
      do {
        try launchAtLogin.setEnabled(wantsLaunchAtLogin)
      } catch {
        launchAtLoginError = error.localizedDescription
        wantsLaunchAtLogin = launchAtLogin.isEnabled()
        return .stayed
      }
    }
    launchAtLoginError = nil
    launchAtLogin.recordChoice()
    outcomes[.openAtLogin] = wantsLaunchAtLogin ? .done : .skipped
    if wantsLaunchAtLogin { announcement = WelcomeCopy.openAtLoginSavedAnnouncement }
    return advance()
  }

  public func setWantsLaunchAtLogin(_ wants: Bool) {
    guard wants != wantsLaunchAtLogin else { return }
    wantsLaunchAtLogin = wants
    launchAtLoginError = nil
  }

  private func closeFromTryIt() -> WelcomeNavigation {
    if !hasDetectedHotkey { outcomes[.tryIt] = .skipped }
    return .close
  }

  // MARK: Live inputs

  /// Call when the window becomes key (the user may have rebound the hotkey).
  public func updateHotkey(_ newValue: WelcomeHotkey) {
    guard newValue != hotkey else { return }
    hotkey = newValue
    if !newValue.isBound { hasDetectedHotkey = false }
  }

  /// Platform feeds step 1 completion (macOS: Accessibility granted; Linux:
  /// keyboard access + extension both settled). `announcement` is spoken only
  /// on a false -> true transition.
  public func updatePermission(isComplete: Bool, announcement: String?) {
    guard isComplete != isPermissionComplete else { return }
    isPermissionComplete = isComplete
    guard isComplete else { return }
    isConfirmingSetUpLater = false
    self.announcement = announcement
    if activeStep == .permission {
      outcomes[.permission] = .done
      _ = advance()
    }
  }

  /// The picker became visible (menu item or hotkey). Only counts on step 3:
  /// opening it while still on the permission step is not "trying the hotkey".
  public func pickerDidShow() {
    guard activeStep == .tryIt, hotkey.isBound, !hasDetectedHotkey else { return }
    hasDetectedHotkey = true
    announcement =
      isHotkeyPendingSetup
      ? WelcomeCopy.tryItOpenedAnnouncement : WelcomeCopy.tryItDetectedAnnouncement
  }

  /// Platform timer fired `WelcomeCopy.tryItHintDelaySeconds` after step 3
  /// became active.
  public func tryItHintTimedOut() {
    guard !hasDetectedHotkey else { return }
    showsTryItHint = true
  }

  /// Linux: a log-out is (no longer) needed. Swaps the last step between
  /// "Try your hotkey" and "Log out to finish setup", moving the user along if
  /// they are already on it.
  public func setNeedsRelogin(_ needs: Bool) {
    guard needs != needsRelogin else { return }
    needsRelogin = needs
    if activeStep == .tryIt || activeStep == .logOut { activeStep = finalStep }
  }

  /// Linux: the global hotkey will not fire until extension setup finishes.
  public func setHotkeyPendingSetup(_ pending: Bool) {
    isHotkeyPendingSetup = pending
  }

  public func clearAnnouncement() { announcement = nil }
}
