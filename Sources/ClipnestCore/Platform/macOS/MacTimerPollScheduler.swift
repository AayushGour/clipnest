import Foundation

#if os(macOS)
  /// Production `PollScheduling` conformance — wraps the exact
  /// `Timer.scheduledTimer` call `ClipboardMonitor.start()` used to make
  /// directly, extracted behind the protocol seam by the Linux port
  /// (P2-A), since a repeating `Timer` needs a live `RunLoop` that a GTK
  /// main loop will not provide. `ClipboardMonitor.start()` still builds
  /// the exact same `[weak self]` + `Task { @MainActor in ... }` tick
  /// closure it always did — only the raw `Timer.scheduledTimer` call
  /// itself moved here, so macOS behavior is unchanged (frozen per D47).
  ///
  /// Idempotency ("don't create a second `Timer` while one is already
  /// running") is deliberately NOT this type's job — `ClipboardMonitor`
  /// already owns that (`isPolling`), per `PollScheduling`'s doc comment,
  /// so `schedule(interval:tick:)` below simply (re)schedules
  /// unconditionally whenever it's called.
  public final class MacTimerPollScheduler: PollScheduling, @unchecked Sendable {
    private var timer: Timer?

    public init() {}

    public func schedule(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
      timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        tick()
      }
    }

    public func cancel() {
      timer?.invalidate()
      timer = nil
    }
  }

  extension PlatformDefaults {
    /// macOS's `PollScheduling` default — `Timer`-backed. See
    /// `MacTimerPollScheduler`.
    public static var pollScheduler: any PollScheduling {
      MacTimerPollScheduler()
    }
  }
#else
  extension PlatformDefaults {
    /// The non-Apple `PollScheduling` default. See `NullPollScheduler`'s
    /// doc comment.
    public static var pollScheduler: any PollScheduling {
      NullPollScheduler()
    }
  }
#endif
