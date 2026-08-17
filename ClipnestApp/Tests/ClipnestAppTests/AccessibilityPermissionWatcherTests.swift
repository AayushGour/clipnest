// AccessibilityPermissionWatcherTests.swift
//
// Covers the transition logic the permission-prompt fix depends on: the
// watcher must fire `onGranted` exactly once, on the false -> true edge, and
// never on a repeat read or a revocation. `HotkeyManager.reinstallMonitors()`
// hangs off that callback, and reinstalling monitors on every poll tick (or
// never reinstalling) are both real bugs.
//
// The real `AXIsProcessTrusted()` is never called — `readTrustState` is
// injected, same rationale as `Paster`'s `isAccessibilityGranted`.

import Testing

@testable import Clipnest

@MainActor
@Suite("AccessibilityPermissionWatcher")
struct AccessibilityPermissionWatcherTests {

  /// Mutable trust state a test can flip between `refresh()` calls. The
  /// watcher's injected reader is `@Sendable`, so this needs to be a
  /// reference type; all access here is main-actor-serialized by the suite's
  /// `@MainActor` isolation, hence `@unchecked`.
  private final class TrustFlag: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
  }

  @Test("initial state is read at init, without polling")
  func readsInitialState() {
    #expect(AccessibilityPermissionWatcher(readTrustState: { true }).isGranted)
    #expect(!AccessibilityPermissionWatcher(readTrustState: { false }).isGranted)
  }

  @Test("refresh publishes a false -> true flip and fires onGranted once")
  func firesOnGrantOnce() {
    let flag = TrustFlag(false)
    let watcher = AccessibilityPermissionWatcher(readTrustState: { flag.value })
    var grantCount = 0
    watcher.onGranted = { grantCount += 1 }

    watcher.refresh()
    #expect(!watcher.isGranted)
    #expect(grantCount == 0)

    flag.value = true
    watcher.refresh()
    #expect(watcher.isGranted)
    #expect(grantCount == 1)

    // Still granted — no edge, so no second reinstall of the hotkey monitors.
    watcher.refresh()
    watcher.refresh()
    #expect(grantCount == 1)
  }

  @Test("revocation is published but does not fire onGranted")
  func revocationDoesNotFireOnGranted() {
    let flag = TrustFlag(true)
    let watcher = AccessibilityPermissionWatcher(readTrustState: { flag.value })
    var grantCount = 0
    watcher.onGranted = { grantCount += 1 }

    flag.value = false
    watcher.refresh()
    #expect(!watcher.isGranted)
    #expect(grantCount == 0)
  }

  @Test("re-granting after a revocation fires again")
  func regrantFiresAgain() {
    let flag = TrustFlag(true)
    let watcher = AccessibilityPermissionWatcher(readTrustState: { flag.value })
    var grantCount = 0
    watcher.onGranted = { grantCount += 1 }

    flag.value = false
    watcher.refresh()
    flag.value = true
    watcher.refresh()
    #expect(watcher.isGranted)
    #expect(grantCount == 1)
  }

  @Test("start() is idempotent")
  func startIsIdempotent() {
    let watcher = AccessibilityPermissionWatcher(readTrustState: { false })
    watcher.start()
    watcher.start()
    watcher.stop()
  }
}
