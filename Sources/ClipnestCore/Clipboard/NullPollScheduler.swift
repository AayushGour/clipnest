import Foundation

/// P2-A (Linux port): the non-Apple default `PollScheduling` conformance —
/// see that protocol's doc comment. Never actually calls `tick` — "never
/// used in production" (`PlatformDefaults.swift`'s documented convention
/// for portable no-op defaults): a real Linux composition root always
/// calls `ClipboardMonitor.startEventDriven()` instead of `start()`
/// (driving `checkNow()` directly from platform clipboard-ownership
/// events), so this scheduler's `schedule(interval:tick:)` is never
/// expected to run in practice. It exists only so `ClipboardMonitor.init`'s
/// `pollScheduler` parameter has *some* non-Apple default to compile
/// against — see `ClipMediaType.swift`'s doc comment for why the seam
/// still needs one even though it's inert off Apple platforms today.
public final class NullPollScheduler: PollScheduling, @unchecked Sendable {
  public init() {}

  public func schedule(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
    // Deliberately does nothing — see this type's doc comment.
  }

  public func cancel() {
    // Nothing was ever scheduled.
  }
}
