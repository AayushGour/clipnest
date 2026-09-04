// SettingsActivatorTests.swift
//
// T-SET1, fix round 2: covers the *sequencing* logic in `SettingsActivator`
// — every AppKit call it makes is injected here, so these tests assert the
// guard/idempotency behavior without touching a real window server (see
// coding-standards.md's testing rules: "mock side effects... never touch
// real system state from a test"). What is NOT covered here, because it
// isn't unit-testable: whether `NSApp.setActivationPolicy`/`NSApp.activate`
// actually raise a real window above another real app's windows on a real
// Mac — that was verified manually (Accessibility tree + CGWindowList, see
// the T-SET1 return writeup) and can't be asserted from an XCTest/Swift
// Testing process without a live interactive login session.
//
// The `ClipnestApp` target's actual Swift module name is `Clipnest` — see
// `ItemKind+SFSymbolTests.swift`'s top doc comment.

import AppKit
import Testing

@testable import Clipnest

@MainActor
@Suite("SettingsActivator")
struct SettingsActivatorTests {

  /// Records every injected call in order, and lets a test invoke the
  /// close handler `SettingsActivator` registered — standing in for "the
  /// window actually closed," without a real `NSWindow.willCloseNotification`
  /// round-trip through `NotificationCenter`.
  @MainActor
  private final class Spy {
    private(set) var policyChanges: [NSApplication.ActivationPolicy] = []
    private(set) var activateCount = 0
    private(set) var observedWindows: [NSWindow] = []
    /// The most recently registered close handler, so a test can simulate
    /// "the window closed" by invoking it directly.
    private(set) var closeHandlers: [() -> Void] = []

    func makeActivator() -> SettingsActivator {
      SettingsActivator(
        setActivationPolicy: { [weak self] policy in
          self?.policyChanges.append(policy)
        },
        activateApp: { [weak self] in
          self?.activateCount += 1
        },
        observeWindowClose: { [weak self] window, handler in
          self?.observedWindows.append(window)
          self?.closeHandlers.append(handler)
        }
      )
    }
  }

  /// A bare, never-shown `NSWindow` used purely as an object identity for
  /// `activate(observing:)` — never ordered front, never made key, so this
  /// touches no real window-server state beyond allocating the object.
  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true)
  }

  @Test("first activate flips to .regular, force-activates, and observes the window's close")
  func firstActivateRunsFullSequence() {
    let spy = Spy()
    let activator = spy.makeActivator()
    let window = makeWindow()

    #expect(!activator.isTemporarilyRegular)

    activator.activate(observing: window)

    #expect(activator.isTemporarilyRegular)
    #expect(spy.policyChanges == [.regular])
    #expect(spy.activateCount == 1)
    #expect(spy.observedWindows.count == 1)
    #expect(spy.observedWindows.first === window)
  }

  @Test(
    "a second activate while still open re-activates but does not re-toggle policy or double-observe"
  )
  func secondActivateWhileOpenReactivatesWithoutRetoggling() {
    let spy = Spy()
    let activator = spy.makeActivator()
    let window = makeWindow()

    activator.activate(observing: window)
    activator.activate(observing: window)
    activator.activate(observing: window)

    // The policy flip and the close observer only ever happen once per
    // open/close cycle...
    #expect(spy.policyChanges == [.regular])
    #expect(spy.observedWindows.count == 1)
    #expect(activator.isTemporarilyRegular)
    // ...but force-activation runs every time. This is the regression
    // guard for a real bug caught by live verification: without it, a
    // second "Settings…" click while the window was already open but had
    // lost focus (the user switched to another app without closing it) did
    // nothing to reclaim focus — see `activate(observing:)`'s doc comment.
    #expect(spy.activateCount == 3)
  }

  @Test("closing the window restores .accessory")
  func windowCloseRestoresAccessory() {
    let spy = Spy()
    let activator = spy.makeActivator()
    let window = makeWindow()

    activator.activate(observing: window)
    #expect(spy.policyChanges == [.regular])

    spy.closeHandlers.first?()

    #expect(spy.policyChanges == [.regular, .accessory])
    #expect(!activator.isTemporarilyRegular)
  }

  @Test("the close handler firing twice only restores once")
  func closeHandlerFiringTwiceRestoresOnce() {
    let spy = Spy()
    let activator = spy.makeActivator()
    let window = makeWindow()

    activator.activate(observing: window)
    spy.closeHandlers.first?()
    spy.closeHandlers.first?()

    #expect(spy.policyChanges == [.regular, .accessory])
  }

  @Test("a fresh open after a close re-arms the full sequence (subsequent opens keep working)")
  func reopenAfterCloseRunsFullSequenceAgain() {
    let spy = Spy()
    let activator = spy.makeActivator()
    let firstWindow = makeWindow()
    let secondWindow = makeWindow()

    activator.activate(observing: firstWindow)
    spy.closeHandlers.first?()
    #expect(!activator.isTemporarilyRegular)

    activator.activate(observing: secondWindow)

    #expect(activator.isTemporarilyRegular)
    #expect(spy.policyChanges == [.regular, .accessory, .regular])
    #expect(spy.activateCount == 2)
    #expect(spy.observedWindows.count == 2)
    #expect(spy.observedWindows.last === secondWindow)
  }
}
