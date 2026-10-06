import Foundation

/// T-RT2: wraps any `ClipStore` and broadcasts a `ClipStoreChange` on
/// `changes` after every mutating call succeeds.
///
/// **The architectural gap this closes:** three independent bugs
/// (T-RT2/T-HANG6/the retention-requery gap) all had the same root cause —
/// a store mutation made from one call site (Settings' "Clear All
/// History…", `PickerViewModel.delete(_:)`, background retention
/// enforcement) had no way to reach any OTHER observer of that same store
/// (an already-open picker holding a stale in-memory window;
/// `ClipboardMonitor`'s pending-OCR bookkeeping, which needs to know a row
/// it scheduled recognition for is gone). Each fix attempted at the call
/// site would have been symptom #4, #5, ... — the NEXT call site that
/// mutates the store would still need to remember to notify everyone by
/// hand.
///
/// **Why a decorator instead of adding this to the `ClipStore` protocol
/// directly:** a protocol requirement (e.g. `var changes: ...{ get }`)
/// would force every conformer — `InMemoryClipStore`, `SwiftDataClipStore`
/// (macOS), `SQLiteClipStore` (Linux) — to add its own storage and thread a
/// `changes.send(...)` call through every one of its mutating methods by
/// hand, which is exactly the "next call site has to remember" failure mode
/// this task rules out, just moved one layer down (a FUTURE fourth
/// `ClipStore` conformer could still forget). Wrapping instead means the
/// broadcasting logic exists in exactly ONE place, and every consumer gets
/// it automatically as long as it's handed THIS wrapped value instead of
/// the raw store — which is already how this codebase wires every store
/// (`AppEnvironment`/`LinuxAppEnvironment` construct exactly one instance
/// and inject it everywhere via `any ClipStore`, never a concrete type). A
/// composition root constructs exactly one `NotifyingClipStore` per real
/// store and hands THIS value to every consumer (`PickerViewModel`,
/// `ClipboardMonitor`, the OCR backfill coordinator, the Settings history
/// tab) instead of the raw store — see those files' doc comments.
///
/// Every read-only method is a pure passthrough — no notification, nothing
/// changed. Every mutating method calls through FIRST, then broadcasts only
/// once the underlying call actually succeeds; a thrown error means nothing
/// changed, so nothing is broadcast (and the error propagates unchanged to
/// the caller).
public final class NotifyingClipStore: ClipStore {
  private let wrapped: any ClipStore

  /// Broadcasts every successful mutation this instance forwards — see this
  /// type's doc comment. Subscribing does not require also holding a
  /// reference to `wrapped`; every read/write still goes through `self`.
  public let changes = ClipStoreChangeBroadcaster()

  public init(wrapping wrapped: any ClipStore) {
    self.wrapped = wrapped
  }

  public func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
    let stored = try await wrapped.insertOrBumpDuplicate(item)
    changes.send(.inserted(stored))
    return stored
  }

  public func fetchAll() async throws -> [ClipItem] {
    try await wrapped.fetchAll()
  }

  public func fetchPinned() async throws -> [ClipItem] {
    try await wrapped.fetchPinned()
  }

  public func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem] {
    try await wrapped.query(text: text, kind: kind, scope: scope, offset: offset, limit: limit)
  }

  public func setPinned(_ id: UUID, pinned: Bool) async throws {
    try await wrapped.setPinned(id, pinned: pinned)
    changes.send(.updated(id))
  }

  public func setRecognizedText(_ id: UUID, text: String) async throws {
    try await wrapped.setRecognizedText(id, text: text)
    changes.send(.updated(id))
  }

  public func fetchImagesNeedingRecognition() async throws -> [ClipItem] {
    try await wrapped.fetchImagesNeedingRecognition()
  }

  public func delete(_ id: UUID) async throws {
    try await wrapped.delete(id)
    changes.send(.deleted(id))
  }

  public func clearHistory() async throws {
    try await wrapped.clearHistory()
    changes.send(.clearedAll)
  }

  public func enforceRetention(cap: RetentionCap?) async throws {
    try await wrapped.enforceRetention(cap: cap)
    // `cap == nil` is documented as an unconditional no-op (nothing is ever
    // deleted) — skip the broadcast in that case so a picker/observer with
    // retention off (the default) never re-queries for a call that provably
    // changed nothing.
    if cap != nil {
      changes.send(.retentionApplied)
    }
  }
}
