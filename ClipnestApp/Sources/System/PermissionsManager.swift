// PermissionsManager.swift
//
// Plan task T16: thin wrapper over macOS's Accessibility trust APIs
// (`ApplicationServices`). Jobs: (1) feed `Paster`'s injectable
// `isAccessibilityGranted` signal in `AppEnvironment` so the real paste path
// knows whether it can synthesize ⌘V, and (2) later back a "Grant
// Accessibility" affordance in Settings (plan task T28) via the prompting
// variant below.
//
// Paste-reliability fix: `AppEnvironment` now feeds `Paster` the *prompting*
// `isGrantedPromptingIfNeeded()` instead of the silent `isGranted` — so a
// paste attempt made without Accessibility granted surfaces macOS's "grant
// access" dialog right there, instead of silently degrading to
// clipboard-only with no explanation. See that method's doc comment for why
// this still only ever prompts from an actual paste attempt, never launch.

// `@preconcurrency`: `ApplicationServices`/`HIServices` predates Swift
// concurrency auditing — `kAXTrustedCheckOptionPrompt` is imported as a
// global `var` (an `extern CFStringRef`), which Swift 6's strict
// concurrency checking otherwise flags as unaudited shared mutable state
// even though it's a read-only constant at runtime.
@preconcurrency import ApplicationServices
import Foundation

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
///
/// No meaningful pure logic to unit test here — a direct passthrough to two
/// system calls, same rationale as `HotkeyManager`'s doc comment. The
/// branching this feeds (`Paster.paste`'s granted/not-granted paths) is
/// already covered by `ClipnestCoreTests/PasterTests.swift` with a mocked
/// `isAccessibilityGranted`.
enum PermissionsManager {
  /// Current Accessibility trust state, checked silently — never shows a
  /// system prompt. This is what feeds `Paster`'s `isAccessibilityGranted`
  /// in `AppEnvironment`; it must stay silent so opening the picker or
  /// selecting an item never blocks the user on an unsolicited permission
  /// dialog (see coding-standards.md's "Accessibility is optional, not
  /// required" privacy must).
  static var isGranted: Bool {
    AXIsProcessTrusted()
  }

  /// Same check, but shows the system "Clipnest would like to control this
  /// computer" prompt (with a link into System Settings > Privacy &
  /// Security > Accessibility) if not already granted. For an explicit,
  /// user-initiated "Grant Accessibility" affordance (Settings, plan task
  /// T28) and — as of the paste-reliability fix below —
  /// `isGrantedPromptingIfNeeded()`. Never called unconditionally/silently;
  /// see that method's doc comment for the one case that does call it.
  @discardableResult
  static func requestAccess() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Checked from an actual paste attempt (fed into `Paster`'s injected
  /// `isAccessibilityGranted` in `AppEnvironment`) — **not** `isGranted`,
  /// deliberately. If Accessibility is already granted, this is silent,
  /// identical to `isGranted`. If it's **not** granted, this calls the
  /// prompting `requestAccess()` so macOS shows its "grant access" dialog
  /// right there, making it obvious *why* the paste that triggered it just
  /// fell back to clipboard-only, instead of silently degrading with no
  /// explanation. Still returns `false` immediately either way — granting
  /// Accessibility requires the user to act in System Settings, it never
  /// takes effect synchronously — so the paste attempt that triggered this
  /// prompt itself still degrades to clipboard-only, exactly as documented;
  /// only a *later* paste attempt, after the user grants it, gets the real
  /// synthesized ⌘V.
  ///
  /// Only ever invoked from an actual paste attempt, never from app launch
  /// or simply opening the picker — `Paster.paste`'s `isAccessibilityGranted`
  /// closure is called nowhere else — matching coding-standards.md's
  /// "Accessibility is optional, not required" privacy must (reading the
  /// pasteboard and opening the picker never require or prompt for it; only
  /// the synthesized-paste step even touches this).
  static func isGrantedPromptingIfNeeded() -> Bool {
    isGranted || requestAccess()
  }
}
