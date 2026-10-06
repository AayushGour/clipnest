import Foundation

/// T-RT2: what changed in a `ClipStore`, broadcast by `NotifyingClipStore`
/// after every mutating call succeeds — see that type's doc comment for the
/// architectural problem this exists to solve (a store mutation made from
/// one call site — Settings' "Clear All History…", background retention
/// enforcement — had no way to reach any OTHER observer of the same store,
/// e.g. an already-open picker, or `ClipboardMonitor`'s pending-OCR
/// bookkeeping).
///
/// Deliberately coarse-grained, not a full diff: every case carries just
/// enough for a subscriber to decide whether/how to react (re-query, cancel
/// a pending job) without this type needing to know anything about who's
/// listening or why.
public enum ClipStoreChange: Sendable, Equatable {
  /// A new item was inserted, or an existing one was bumped to the top via
  /// dedup (`ClipStore.insertOrBumpDuplicate`).
  case inserted(ClipItem)
  /// An existing item's metadata changed in place — a pin toggle
  /// (`setPinned`) or recognized text being recorded (`setRecognizedText`).
  case updated(UUID)
  /// A single item (and its blob, if any) was deleted (`ClipStore.delete`).
  case deleted(UUID)
  /// Every item was deleted (`ClipStore.clearHistory`) — including pinned
  /// ones.
  case clearedAll
  /// `ClipStore.enforceRetention(cap:)` ran and may have trimmed an
  /// unspecified set of unpinned items (pinned items are never affected).
  /// Carries no ids: `enforceRetention` itself reports only success/failure,
  /// not which rows it removed — a subscriber that cares whether its
  /// currently-displayed data is still accurate should treat this the same
  /// as `deleted`/`clearedAll` (re-query), just without a specific id to
  /// target.
  case retentionApplied
}
