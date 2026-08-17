// PermissionsManager.swift
//
// Plan task T16: thin wrapper over macOS's Accessibility trust APIs
// (`ApplicationServices`), plus the live-state watcher the Settings UI and
// `HotkeyManager` both need.
//
// Permission-prompt fix: nothing in Clipnest ever calls the *prompting*
// variant implicitly any more. Every code path that merely needs to KNOW the
// trust state reads the silent `isGranted`; the prompting `requestAccess()`
// is reachable only from an explicit user action (the Permissions settings
// tab's button) and from exactly one one-shot first-run nudge, gated on
// `SettingsStore.hasRequestedAccessibility`. That is what stops the old
// behavior where every single paste attempt re-ran the prompting check and
// macOS put its "Clipnest would like to control this computer" dialog on
// screen again.

// `@preconcurrency`: `ApplicationServices`/`HIServices` predates Swift
// concurrency auditing — `kAXTrustedCheckOptionPrompt` is imported as a
// global `var` (an `extern CFStringRef`), which Swift 6's strict
// concurrency checking otherwise flags as unaudited shared mutable state
// even though it's a read-only constant at runtime.
import AppKit
@preconcurrency import ApplicationServices
import Foundation
import Observation

/// Wraps `AXIsProcessTrusted()`/`AXIsProcessTrustedWithOptions(_:)` so the
/// rest of the app never calls the raw `ApplicationServices` APIs directly —
/// per coding-standards.md's "Config in one place" / consistency rule, this
/// is the single place that reads Accessibility trust state.
///
/// Deliberately not `@MainActor`: both underlying calls are plain C
/// functions safe to invoke from any thread, and `Paster`'s injected
/// `isAccessibilityGranted` closure is itself `@Sendable`/non-isolated (see
/// `Paster.init`) — keeping `PermissionsManager` non-isolated lets
/// `{ PermissionsManager.isGranted }` be passed straight through with no
/// actor hop.
enum PermissionsManager {
  /// Current Accessibility trust state, checked silently — never shows a
  /// system prompt. This is what feeds `Paster`'s `isAccessibilityGranted`
  /// in `AppEnvironment` and what `AccessibilityPermissionWatcher` polls.
  static var isGranted: Bool {
    AXIsProcessTrusted()
  }

  /// Same check, but shows the system "Clipnest would like to control this
  /// computer" prompt (with a link into System Settings > Privacy &
  /// Security > Accessibility) when not already granted.
  ///
  /// **Only ever call this from an explicit user action** (the Permissions
  /// tab's Grant button) or the one-shot first-run nudge in `AppEnvironment`.
  /// Anything that just needs the state must read `isGranted` instead —
  /// see this file's header.
  ///
  /// Returns the trust state as it was at call time, so a `false` return
  /// here does NOT mean the user declined: granting requires them to act in
  /// System Settings, which never takes effect synchronously.
  /// `AccessibilityPermissionWatcher` is what notices the eventual flip.
  @discardableResult
  static func requestAccess() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Opens System Settings straight to Privacy & Security › Accessibility.
  /// Used by the Permissions tab, including for the stale-grant case where
  /// macOS's own prompt would be useless (see
  /// `AccessibilityPermissionWatcher` for what "stale" means here).
  @MainActor
  static func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }
}

/// Observable, live Accessibility trust state.
///
/// Exists because macOS provides no notification for a TCC grant changing:
/// the user leaves the app, flips a switch in System Settings, and comes
/// back. Polling `AXIsProcessTrusted()` is the only way to notice. The poll
/// is cheap (a single C call) and deliberately slow — `notGrantedInterval`
/// while we're waiting on the user, `grantedInterval` once granted, purely
/// to notice a later revocation.
///
/// `onGranted` exists for `HotkeyManager`: an `NSEvent` global key monitor
/// installed while untrusted stays permanently dead even after the grant
/// lands, so the monitors have to be torn down and reinstalled at the moment
/// the state flips. See `HotkeyManager.reinstallMonitors()`.
@MainActor
@Observable
final class AccessibilityPermissionWatcher {
  /// Poll cadence while Accessibility is NOT granted — fast enough that
  /// returning from System Settings feels immediate.
  static let notGrantedInterval: Duration = .seconds(1)

  /// Poll cadence once granted — only there to notice a revocation, so it
  /// can be lazy.
  static let grantedInterval: Duration = .seconds(10)

  private(set) var isGranted: Bool

  /// Invoked on every false -> true transition, never on the initial read.
  @ObservationIgnored var onGranted: (() -> Void)?

  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private let readTrustState: @Sendable () -> Bool

  /// `readTrustState` is injected so tests can drive transitions without
  /// touching the real permission — same rationale as `Paster`'s injected
  /// `isAccessibilityGranted`.
  init(readTrustState: @escaping @Sendable () -> Bool = { PermissionsManager.isGranted }) {
    self.readTrustState = readTrustState
    self.isGranted = readTrustState()
  }

  deinit {
    pollTask?.cancel()
  }

  /// Starts polling. Safe to call more than once — a second call is a no-op
  /// rather than a second concurrent poll loop.
  func start() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let interval =
          self.isGranted
          ? Self.grantedInterval
          : Self.notGrantedInterval
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        self.refresh()
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
  }

  /// Re-reads trust state now and fires `onGranted` if this is the moment it
  /// became granted. Called by the poll loop, and directly by the Permissions
  /// tab so a returning user sees the new state without waiting a full tick.
  func refresh() {
    let latest = readTrustState()
    guard latest != isGranted else { return }
    isGranted = latest
    if latest {
      onGranted?()
    }
  }
}
