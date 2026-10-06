import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// Records every `postKeyEvent` call it receives — lets
/// `ForceReleaseModifierGuardTests` assert the EXACT keycode/press
/// sequence without a real `/dev/uinput` fd. `@unchecked Sendable`
/// matches this test target's existing convention for single-owner test
/// fakes (`FakeModifierMaskReader` in `InputModifierReleaseWaiterTests`).
private final class FakeKeyEventPosting: KeyEventPosting, @unchecked Sendable {
  private(set) var calls: [(code: UInt16, isPress: Bool)] = []
  /// Codes for which `postKeyEvent` should report failure — simulates a
  /// write to `/dev/uinput` failing partway through.
  var failingCodes: Set<UInt16> = []

  func postKeyEvent(code: UInt16, isPress: Bool) -> Bool {
    calls.append((code, isPress))
    return !failingCodes.contains(code)
  }
}

@Suite("ForceReleaseModifierGuard")
struct ForceReleaseModifierGuardTests {
  @Test("releases every tracked modifier keycode, all as key-up, in order")
  func releasesEveryTrackedModifier() {
    let device = FakeKeyEventPosting()
    let guardStrategy = ForceReleaseModifierGuard(device: device)

    #expect(guardStrategy.clearInterferingModifiers() == true)
    #expect(device.calls.map(\.code) == LinuxEventCode.allModifierKeycodes)
    #expect(device.calls.allSatisfy { $0.isPress == false })
  }

  @Test("covers both left and right variants of every ModifierMask family")
  func coversLeftAndRightVariants() {
    let device = FakeKeyEventPosting()
    _ = ForceReleaseModifierGuard(device: device).clearInterferingModifiers()

    let posted = Set(device.calls.map(\.code))
    #expect(posted.isSuperset(of: [LinuxEventCode.keyLeftCtrl, LinuxEventCode.keyRightCtrl]))
    #expect(posted.isSuperset(of: [LinuxEventCode.keyLeftShift, LinuxEventCode.keyRightShift]))
    #expect(posted.isSuperset(of: [LinuxEventCode.keyLeftAlt, LinuxEventCode.keyRightAlt]))
    #expect(posted.isSuperset(of: [LinuxEventCode.keyLeftMeta, LinuxEventCode.keyRightMeta]))
  }

  @Test("stops and reports failure the moment a uinput write fails")
  func stopsOnFirstFailure() {
    let device = FakeKeyEventPosting()
    device.failingCodes = [LinuxEventCode.keyLeftShift]

    let succeeded = ForceReleaseModifierGuard(device: device).clearInterferingModifiers()

    #expect(succeeded == false)
    // Never attempted anything past the failing code — matches
    // `UInputEventSynthesizer.post`'s own "abandon on first failed write"
    // shape elsewhere in this module.
    #expect(device.calls.last?.code == LinuxEventCode.keyLeftShift)
  }
}

@Suite("WaitForReleaseModifierGuard")
struct WaitForReleaseModifierGuardTests {
  @Test("reports cleared when the wrapped waiter observes release")
  func reportsClearedOnRelease() {
    let waiter = ModifierReleaseWaiter(
      reader: ConstantModifierMaskReader(mask: []),
      pollInterval: .milliseconds(10), releaseCeiling: .milliseconds(40),
      sleep: { _ in })
    #expect(WaitForReleaseModifierGuard(waiter: waiter).clearInterferingModifiers() == true)
  }

  @Test("reports NOT cleared when the wrapped waiter times out")
  func reportsNotClearedOnTimeout() {
    let waiter = ModifierReleaseWaiter(
      reader: ConstantModifierMaskReader(mask: .shift),
      pollInterval: .milliseconds(10), releaseCeiling: .milliseconds(20),
      sleep: { _ in })
    #expect(WaitForReleaseModifierGuard(waiter: waiter).clearInterferingModifiers() == false)
  }
}

/// A `ModifierMaskReading` that always answers the same fixed mask —
/// simpler than `InputModifierReleaseWaiterTests`' queue-based fake since
/// these tests only need "always released" / "never released", not a
/// scripted sequence.
private struct ConstantModifierMaskReader: ModifierMaskReading {
  let mask: ModifierMask
  func currentModifierMask() -> ModifierMask { mask }
}
