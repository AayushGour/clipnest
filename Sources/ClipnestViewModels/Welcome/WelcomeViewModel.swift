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

  public var number: Int { rawValue }
  public static var count: Int { allCases.count }

  public var heading: String {
    switch self {
    case .permission: return WelcomeCopy.permissionHeading
    case .openAtLogin: return WelcomeCopy.openAtLoginHeading
    case .tryIt: return WelcomeCopy.tryItHeading
    }
  }
}

/// Where keyboard focus belongs (never Skip).
public enum WelcomeInitialFocus: Equatable, Sendable {
  /// The step's own action (macOS "Allow Accessibility…") - permission missing.
  case permissionAction
  /// The footer primary button (Continue) - permission already granted.
  case primaryButton
  /// The "Open Clipnest at login" switch, while that step is active.
  case launchAtLoginToggle
}

public enum WelcomeStepState: Equatable, Sendable {
  case upcoming, current, done, skipped

  /// The state word VoiceOver/Orca read ("upcoming" steps read "optional"
  /// only for the optional step 1, handled by the VM).
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

  private let launchAtLogin: WelcomeLaunchAtLogin
  private var outcomes: [WelcomeStep: WelcomeStepState] = [:]

  /// - Parameter launchAtLoginPreChecked: the switch's starting value. Platforms
  ///   pass `true` (recommended) until the user has chosen once, then the real
  ///   system state, so reopening "Getting Started…" never re-enables a
  ///   login item the user turned off in Settings. Both Continue and Skip on
  ///   the open-at-login step call `launchAtLogin.recordChoice` (Skip leaves the
  ///   login state itself untouched), so "until the user has chosen" means
  ///   "has answered that step either way".
  public init(
    platform: WelcomePlatform, hotkey: WelcomeHotkey, isPermissionComplete: Bool,
    launchAtLogin: WelcomeLaunchAtLogin, launchAtLoginPreChecked: Bool = true
  ) {
    self.launchAtLogin = launchAtLogin
    wantsLaunchAtLogin = launchAtLoginPreChecked
    self.platform = platform
    self.hotkey = hotkey
    self.isPermissionComplete = isPermissionComplete
    // Always starts on the permission step; an already-granted one reads
    // "Allowed" with Continue focused (`initialFocus`).
    activeStep = .permission
  }

  public var initialFocus: WelcomeInitialFocus {
    isPermissionComplete ? .primaryButton : .permissionAction
  }

  /// Where focus belongs NOW, given whether the platform currently shows step
  /// 1's action button. Platforms re-apply it when the active step changes or
  /// the button disappears, so focus never lands on nothing (or on Skip).
  public func focusTarget(permissionActionAvailable: Bool) -> WelcomeInitialFocus {
    switch activeStep {
    case .permission:
      return !isPermissionComplete && permissionActionAvailable ? .permissionAction : .primaryButton
    case .openAtLogin: return .launchAtLoginToggle
    case .tryIt: return .primaryButton
    }
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
    activeStep == WelcomeStep.allCases.last ? WelcomeCopy.doneTitle : WelcomeCopy.continueTitle
  }

  public func accessibilityLabel(for step: WelcomeStep) -> String {
    let state = state(of: step)
    let word = (step == .permission && state == .upcoming) ? "optional" : state.spoken
    return WelcomeCopy.stepAccessibilityLabel(
      number: step.number, count: WelcomeStep.count, heading: step.heading, state: word)
  }

  // MARK: Copy

  public var permissionBodyText: String { WelcomeCopy.permissionBody(platform: platform) }

  public var openAtLoginBodyText: String { WelcomeCopy.openAtLoginBody }

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
  /// first applies the login-item choice.
  public func continueTapped() -> WelcomeNavigation {
    switch activeStep {
    case .permission:
      outcomes[.permission] = isPermissionComplete ? .done : .skipped
      return advance()
    case .openAtLogin:
      return applyLaunchAtLogin()
    case .tryIt:
      return closeFromTryIt()
    }
  }

  /// "Skip": skips the current step; on the last step it closes.
  public func skipTapped() -> WelcomeNavigation {
    switch activeStep {
    case .permission, .openAtLogin:
      // Skipping step 2 leaves the system untouched (nothing is applied) but
      // still counts as an answer, so the next Getting Started shows reality.
      if activeStep == .openAtLogin { launchAtLogin.recordChoice() }
      outcomes[activeStep] = .skipped
      return advance()
    case .tryIt:
      return closeFromTryIt()
    }
  }

  private func advance() -> WelcomeNavigation {
    guard let next = WelcomeStep(rawValue: activeStep.rawValue + 1) else { return .close }
    activeStep = next
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

  /// Linux: the global hotkey will not fire until extension setup finishes.
  public func setHotkeyPendingSetup(_ pending: Bool) {
    isHotkeyPendingSetup = pending
  }

  public func clearAnnouncement() { announcement = nil }
}
