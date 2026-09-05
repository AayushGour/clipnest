#if canImport(Glibc)
  import Glibc
#endif
import Foundation

/// The real, blocking sleep `ModifierReleaseWaiter` uses outside tests — a
/// plain enum rather than a closure literal at each call site, so there is
/// exactly one place that converts a `Duration` into a `usleep(3)`
/// microsecond count.
///
/// `EventSynthesizing.synthesizeCommandV` (`ClipnestCore/Paste/
/// EventSynthesizing.swift`) is a synchronous, non-`async` protocol
/// requirement, so the modifier-release wait it drives cannot suspend via
/// `Task.sleep` — it blocks the calling thread for up to
/// `InputConstants.modifierReleaseCeiling` (400ms) in the worst case. This
/// mirrors how the equivalent Accessibility IPC calls
/// (`ATSPITextAccessor`, `AXUIElementCopyAttributeValue` on macOS) are
/// already synchronous/blocking by the shape of the contract they
/// implement; a composition root that wants to keep this off its main
/// thread should invoke `Paster.paste` from a non-`@MainActor` `Task`.
public enum BlockingSleep {
  /// Converts `duration` to whole microseconds for `usleep(3)`, clamped to
  /// `UInt32.max` (usleep's argument type). `duration` is always one of the
  /// small, fixed poll intervals this module uses in production — nowhere
  /// close to that bound — but a pure conversion should never trap on an
  /// out-of-range input either.
  public static func microseconds(for duration: Duration) -> UInt32 {
    let seconds = Double(duration.components.seconds)
    let attoseconds = Double(duration.components.attoseconds)
    let totalMicroseconds = seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    guard totalMicroseconds.isFinite, totalMicroseconds > 0 else { return 0 }
    return UInt32(min(totalMicroseconds, Double(UInt32.max)))
  }

  /// Manual-verify only beyond the pure conversion above: `usleep` is a
  /// real blocking syscall-backed C library call with nothing left to
  /// unit-test once `microseconds(for:)` is covered.
  public static func sleep(_ duration: Duration) {
    #if canImport(Glibc)
      Glibc.usleep(microseconds(for: duration))
    #endif
  }
}
