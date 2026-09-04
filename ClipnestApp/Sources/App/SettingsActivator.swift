// SettingsActivator.swift
//
// T-SET1, fix round 2: extracted out of `MenuBarContent.openSettingsAndFocus()`
// (see that method's doc comment in `ClipnestApp.swift` for the full root-cause
// story) purely so the *sequencing* around the activation-policy dance has
// automated coverage. Every AppKit call is injected via closures, so
// `SettingsActivatorTests` can assert the guard/idempotency logic — "don't
// re-toggle if already regular," "restore exactly once," "a fresh open after
// a close re-arms the whole sequence" — without a live window server. The
// AppKit calls themselves (actually flipping the activation policy, actually
// activating, actually ordering a window front) are NOT unit-testable; see
// `openSettingsAndFocus`'s doc comment for how those are verified manually.

import AppKit

/// Bridges Clipnest's steady-state `.accessory` activation policy (no Dock
/// icon, no ⌘-Tab entry — see `AppDelegate`) past the one moment that policy
/// actively works against the app: bringing the Settings window in front of
/// whatever app the user is currently in.
///
/// Root cause (confirmed live on macOS 26.6.2, T-SET1): an `.accessory`
/// policy app has no Dock icon, and macOS will not select/activate a window
/// belonging to an app with no Dock icon — no matter how many times
/// `makeKeyAndOrderFront`/`orderFrontRegardless`/deprecated
/// `NSApp.activate(ignoringOtherApps:)` are called. The Settings window
/// really does open (`MenuBarContent.settingsWindow()` finds it,
/// `CGWindowListCopyWindowInfo` shows it on-screen) — it just never rises
/// above whatever the user was already looking at, because the app itself
/// is never actually made frontmost. Independently corroborated by Peter
/// Steinberger's "Showing Settings from macOS Menu Bar Items" (Jun 2025,
/// steipete.me), which documents this exact failure mode on macOS Tahoe
/// (26) and ships the identical fix in production (VibeTunnel).
///
/// The fix — the same one every other `.accessory`-policy menu-bar utility
/// uses for its Preferences window — is to briefly flip to `.regular`
/// (which makes the window selectable again, and shows a Dock icon for as
/// long as Settings stays open), force-activate, then flip back to
/// `.accessory` once the Settings window closes. NOT on a timer, and NOT
/// immediately after activating: restoring right away would drop the
/// activation before the window server finishes processing it (the window
/// would sink right back behind whatever it was raised above), and never
/// restoring would leave a permanent Dock icon. Tying the restore to the
/// window's own close notification is the only point that is both late
/// enough and guaranteed to fire.
///
/// Rejected alternatives (do not revert to these):
///  - **More `orderFrontRegardless()` calls / a longer `RunLoop` delay.**
///    Round 1 of this fix already tried this. It cannot work: the
///    constraint is "no Dock icon => the app can't be made frontmost at
///    all," which no amount of window-ordering or waiting touches.
///  - **`NSRunningApplication.current.activate(options:)`.** A different
///    entry point onto the identical "accessory apps aren't selectable"
///    rule `NSApp.activate` hits. `.activateAllWindows` only controls
///    whether an app's *other* windows also raise once it's activated — it
///    doesn't grant selectability to an app with no Dock icon in the first
///    place.
///  - **Cooperative `NSApplication.activate()` (macOS 14+, non-deprecated)
///    + `NSApp.yieldActivation(to:)`.** Two separate problems: cooperative
///    activation is explicitly allowed to decline, which is the opposite of
///    what an explicit "Settings…" click needs (the whole point is to
///    steal focus from whatever app the user is in); and `yieldActivation`
///    solves the opposite direction of the problem — temporarily letting
///    *another* app activate ahead of yours (e.g. while launching a
///    helper) — there is no "other app" to yield to here.
///
/// `ignoringOtherApps: true` is still deprecated as of macOS 14, and still
/// the right call here for the same reason round 1 chose it: cooperative
/// activation may simply decline, and declining is exactly wrong for a
/// direct user click on "Settings…". What changed on macOS 26 is not which
/// activation call to use — it's that activation (of either kind) is now a
/// no-op for a Dock-icon-less app, which only the `.regular` policy flip
/// fixes.
@MainActor
final class SettingsActivator {
  private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
  private let activateApp: () -> Void
  private let observeWindowClose: (NSWindow, @escaping @Sendable () -> Void) -> Void

  /// `true` for exactly the span the app is temporarily `.regular` (i.e.
  /// Settings is open and hasn't closed yet). Exposed so tests can assert
  /// the guard behavior directly; production code never reads it.
  private(set) var isTemporarilyRegular = false

  init(
    setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
    activateApp: @escaping () -> Void,
    observeWindowClose: @escaping (NSWindow, @escaping @Sendable () -> Void) -> Void
  ) {
    self.setActivationPolicy = setActivationPolicy
    self.activateApp = activateApp
    self.observeWindowClose = observeWindowClose
  }

  /// Wired to the real `NSApp`/`NotificationCenter` — the one instance the
  /// app actually runs (`MenuBarContent.activator`).
  static func live() -> SettingsActivator {
    SettingsActivator(
      setActivationPolicy: { NSApp.setActivationPolicy($0) },
      activateApp: {
        // See the type's doc comment for why this stays
        // `ignoringOtherApps: true` rather than macOS 14's cooperative
        // `NSApp.activate()`.
        NSApp.activate(ignoringOtherApps: true)
      },
      observeWindowClose: { window, handler in
        // A plain `NotificationCenter` observer, NOT `window.delegate =`:
        // the Settings window is a SwiftUI-managed `NSWindow` this code
        // doesn't own, and clobbering its delegate risks breaking whatever
        // SwiftUI itself relies on it for. One-shot by construction — the
        // observer removes itself the first (and only) time it fires.
        //
        // The token has to be readable from inside the very closure that
        // creates it (to remove itself), which is exactly the shape
        // `PickerPanel.localKeyMonitor`'s doc comment already
        // justifies `nonisolated(unsafe)` for: a boxed reference type
        // sidesteps Swift 6 strict concurrency flagging a captured `var`
        // mutated after capture in this `@Sendable` closure. Safe for the
        // same reason as that property — `box.token` is written exactly
        // once, synchronously, immediately below, and the only other access
        // is this closure firing later on `queue: .main`, which by
        // construction cannot run concurrently with that synchronous write.
        let box = ObserverTokenBox()
        box.token = NotificationCenter.default.addObserver(
          forName: NSWindow.willCloseNotification,
          object: window,
          queue: .main
        ) { _ in
          if let token = box.token {
            NotificationCenter.default.removeObserver(token)
          }
          handler()
        }
      }
    )
  }

  /// Flips to `.regular` (if not already), force-activates, and — the first
  /// time only — arranges to flip back to `.accessory` the next time
  /// `window` closes. Call every time `window` (the Settings window) has
  /// been located and is about to be raised, including on repeat
  /// "Settings…" clicks while it's already open.
  ///
  /// `setActivationPolicy`/the close observer are idempotent (guarded by
  /// `isTemporarilyRegular`) — a second call while already `.regular`
  /// doesn't re-toggle the policy or register a second close observer for
  /// the same window (that alone would be harmless, since both
  /// `restoreAccessory()` and the observer's own removal are themselves
  /// guarded/one-shot, but it would leak an observer per extra click).
  ///
  /// `activateApp()`, in contrast, is called on **every** invocation, not
  /// just the first — this was a real bug caught by live verification, not
  /// a hypothetical: focus can be stolen away from an already-open Settings
  /// window (the user switches to another app without closing it) and then
  /// reclaimed via a second "Settings…" click. Gating `activateApp()`
  /// behind the same `isTemporarilyRegular` guard as the policy flip meant
  /// that second click silently did nothing — the window was still
  /// genuinely `.regular` and already on-screen, so nothing *looked* wrong
  /// in a quick check, but the app was never re-activated, so it stayed
  /// behind whatever the user had switched to. Force-activating an already-
  /// active app is a harmless no-op, so there is no cost to calling it
  /// unconditionally here.
  func activate(observing window: NSWindow) {
    if !isTemporarilyRegular {
      isTemporarilyRegular = true
      setActivationPolicy(.regular)
      observeWindowClose(window) { [weak self] in
        // `observeWindowClose`'s handler is `@Sendable` (it has to be, to
        // be capturable by `NotificationCenter`'s own `@Sendable`
        // callback — see `live()`'s doc comment), so this closure body is
        // nonisolated as far as the compiler is concerned even though
        // every real caller (`live()`) only ever invokes it via
        // `queue: .main`. `MainActor.assumeIsolated` is the same bridge
        // `HotkeyManager`'s `observeLibraryNotifications()` already uses
        // for the identical "`NotificationCenter` callback on
        // `queue: .main`, calling back into `@MainActor` state" shape.
        MainActor.assumeIsolated {
          self?.restoreAccessory()
        }
      }
    }
    activateApp()
  }

  /// Restores `.accessory`. Guarded so firing twice (which can't happen
  /// through the one-shot observer above, but is cheap to protect against
  /// regardless) is a no-op rather than a redundant `setActivationPolicy`
  /// call.
  private func restoreAccessory() {
    guard isTemporarilyRegular else { return }
    isTemporarilyRegular = false
    setActivationPolicy(.accessory)
  }
}

/// A one-property box purely so `SettingsActivator.live()`'s one-shot
/// `NotificationCenter` observer (see its doc comment) can hold its own
/// removal token without Swift 6 strict concurrency flagging a captured
/// `var` mutated after capture — same `nonisolated(unsafe)` justification
/// as `PickerPanel.localKeyMonitor`. `@unchecked Sendable` for the same
/// reason: the single write happens synchronously before the closure that
/// reads it can possibly run.
private final class ObserverTokenBox: @unchecked Sendable {
  nonisolated(unsafe) var token: NSObjectProtocol?
}
