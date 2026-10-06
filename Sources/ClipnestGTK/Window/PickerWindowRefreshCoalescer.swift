// PickerWindowRefreshCoalescer.swift
//
// P10-D (Linux port, GTK4 view layer): the pure half of turning
// `PickerViewModel.objectWillChange` notifications into GTK redraws — see
// `PickerWindow+Reconcile.swift`'s top doc comment for the untestable GTK
// edge that drives this.
//
// `objectWillChange` fires BEFORE every `@Published` mutation, and one user
// action (a keystroke, an arrow key, a background capture landing) touches
// several `@Published` properties in a row (e.g. `willShow()` alone bumps
// `isVisible`, `currentSearchText`, `isSearching`, `query`, `focusToken`,
// and `searchResetToken`). Reconciling once per individual notification
// would therefore run — and sometimes fully rebuild `listBox`, see
// `PickerWindow+Rows.swift` — several times per action, which is WORSE than
// the fixed-interval poll this replaces. This type is the fix: it tracks
// whether a reconcile is already pending and reports whether a NEW one
// needs to be scheduled, so any number of notifications arriving before the
// pending one actually runs collapse into that single upcoming reconcile
// for free (it reads `PickerViewModel`'s CURRENT state whenever it finally
// fires, not a stale snapshot from whichever notification triggered it).
//
// Deliberately holds no reference to `PickerViewModel`/`PickerWindow`/GTK at
// all — just the one boolean this decision needs — so it's fully
// constructible and testable (`GTKPickerRefreshCoalescerTests.swift`)
// without a live `GMainContext`, a display, or any GTK call whatsoever.
// Not `Sendable`/thread-safe by design: constructed and used exclusively
// from `PickerWindow`, itself proven single-GTK-thread only (see that
// type's "ACTOR ISOLATION" doc comment) — there is never a second caller to
// race against.
public final class PickerWindowRefreshCoalescer {
  private var isScheduled = false

  public init() {}

  /// Call this from every `objectWillChange` notification. Returns `true`
  /// exactly when the caller should actually schedule a new refresh (via
  /// `g_idle_add_full` in production) — i.e. only when nothing is already
  /// pending; returns `false` every other time until `markRefreshStarted()`
  /// re-arms it.
  public func beginRefreshIfNeeded() -> Bool {
    guard !isScheduled else { return false }
    isScheduled = true
    return true
  }

  /// Call this once the scheduled refresh actually starts running (or is
  /// cancelled before it got the chance to) — clears the "already
  /// scheduled" flag so the NEXT `beginRefreshIfNeeded()` (from a
  /// notification that arrives after this point) schedules a fresh one
  /// instead of being silently dropped.
  public func markRefreshStarted() {
    isScheduled = false
  }
}
