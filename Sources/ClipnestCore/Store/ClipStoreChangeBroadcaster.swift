import Foundation

/// T-RT2: a minimal, cross-platform (Foundation-only) multi-subscriber
/// pub/sub used by `NotifyingClipStore` to fan a `ClipStoreChange` out to
/// every current subscriber — the mechanism that lets a store mutation made
/// by ANY call site reach every other observer of that same store instance,
/// without either side knowing about the other.
///
/// **Why a new type, not `Combine` or `ClipnestObservation`:** `ClipStore`
/// (this file's module, `ClipnestCore`) has to compile identically on macOS
/// and Linux with no `#if canImport(Combine)` branching — unlike
/// `PickerViewModel`, which already needs that branch for its own
/// `@Published` property wrappers. `Combine` doesn't exist on Linux, so it
/// can't appear in `ClipnestCore` at all. `ClipnestObservation`'s
/// `ObservableObjectPublisher` (built by a parallel task, see
/// `ClipnestObservation/ObservableObject.swift`) doesn't fit either: it's a
/// same-module stand-in scoped specifically to replicating Combine's
/// `@Published`/`ObservableObject` wiring for `ClipnestViewModels` types,
/// its `send()` takes no payload (every `ClipStore` subscriber here needs to
/// know exactly WHAT changed — which id, or a full clear), and `ClipnestCore`
/// has no dependency on the `ClipnestObservation` target today (and
/// shouldn't gain one just for this — `ClipnestObservation` sits ABOVE
/// `ClipnestCore` in the dependency graph, pulled in by `ClipnestViewModels`,
/// never the other way around). A small dependency-free broadcaster local to
/// this module is the correct-sized fix.
///
/// Delivery is synchronous, on whatever thread/task `send(_:)` is called
/// from (a `ClipStore` conformer's own actor executor, in practice) — this
/// type does no isolation-hopping of its own, matching every other
/// cross-boundary closure in this codebase (`ClipboardMonitor.onCapture`,
/// `PickerViewModel.dismiss`, …): the SUBSCRIBER'S closure is responsible for
/// hopping to whatever actor it needs (typically `Task { @MainActor in ... }`
/// — see `AppEnvironment`/`LinuxAppEnvironment`'s subscription for the
/// pattern).
public final class ClipStoreChangeBroadcaster: @unchecked Sendable {
  private let lock = NSLock()
  private var handlersByToken: [UUID: @Sendable (ClipStoreChange) -> Void] = [:]

  public init() {}

  /// Registers `handler` to be called on every future `send(_:)`. Returns a
  /// token that unregisters `handler` when explicitly `cancel()`ed OR when
  /// the token itself deallocates (mirrors `ClipnestObservation
  /// .ObservationCancellable`'s auto-cancel-on-deinit — see that type's doc
  /// comment for the same "subscriber owns a token, dropping it unsubscribes"
  /// shape) — so a subscriber that stores the returned token as an instance
  /// property is unsubscribed automatically when IT deallocates, with no
  /// separate teardown call required.
  ///
  /// Deliberately NOT `@discardableResult`, matching `Combine.sink`'s own
  /// convention for the exact same reason: `_ = broadcaster.subscribe { ... }`
  /// unsubscribes again immediately (the discarded token deallocates on the
  /// spot) — a silent, easy-to-write no-op otherwise. Requiring the caller to
  /// bind the result surfaces that mistake as a compiler warning instead.
  public func subscribe(
    _ handler: @escaping @Sendable (ClipStoreChange) -> Void
  ) -> ClipStoreChangeSubscription {
    let token = UUID()
    lock.lock()
    handlersByToken[token] = handler
    lock.unlock()
    return ClipStoreChangeSubscription { [weak self] in
      self?.unsubscribe(token)
    }
  }

  /// Calls every currently-registered handler with `change`, in registration
  /// order. Safe to call with zero subscribers (a no-op) — `NotifyingClipStore`
  /// calls this unconditionally after every successful mutation, regardless
  /// of whether anything is listening yet.
  public func send(_ change: ClipStoreChange) {
    lock.lock()
    let handlers = Array(handlersByToken.values)
    lock.unlock()
    for handler in handlers {
      handler(change)
    }
  }

  private func unsubscribe(_ token: UUID) {
    lock.lock()
    handlersByToken.removeValue(forKey: token)
    lock.unlock()
  }
}

/// Returned by `ClipStoreChangeBroadcaster.subscribe(_:)` — cancels that
/// subscription, either explicitly via `cancel()` or implicitly on `deinit`.
/// A subscriber keeps this alive (typically as a stored property) for as
/// long as it wants to keep receiving changes.
public final class ClipStoreChangeSubscription: Sendable {
  private let cancelAction: @Sendable () -> Void

  init(cancelAction: @escaping @Sendable () -> Void) {
    self.cancelAction = cancelAction
  }

  public func cancel() {
    cancelAction()
  }

  deinit {
    cancelAction()
  }
}
