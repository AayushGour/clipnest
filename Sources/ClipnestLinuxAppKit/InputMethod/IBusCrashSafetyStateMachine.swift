import ClipnestViewModels
import Foundation

/// The persisted-marker key this state machine owns — kept in one place
/// per coding-standards.md's "no magic strings" rule. Reuses the SAME
/// `KeyValueStore` seam `SettingsStore` already persists through (real
/// on-disk JSON on Linux, see `KeyValueStore.swift`'s own doc comment) —
/// no new dotfile, per this task's brief.
enum IBusEngineRestoreMarker {
  static let key = "ibus.pendingRestoreGlobalEngineName"
}

/// D-IBUS-3's crash-safety state machine for IBus's global-engine
/// switch/restore transaction: **persist the previous engine name before
/// ever switching; clear that marker only after the restore is CONFIRMED;
/// at startup, before anything else runs, force-restore from the marker if
/// one is left over from a run that died mid-transaction.**
///
/// Pure logic only — a `KeyValueStore` witness and plain `(String) -> Bool`
/// closures for "call `SetGlobalEngine`", no `DBusConnection`/socket code —
/// so every branch is exercised directly by `IBusCrashSafetyStateMachineTests`
/// with a fake store and fake closures, no real bus needed.
/// `IBusCommitClient` (the live caller) supplies real closures that call
/// through its own `callConnection`.
///
/// **Why this exists at all — the user-facing hazard.** If Clipnest dies
/// between switching the global engine to itself and confirming the
/// restore, the user is left on a dead engine (nothing else is registered
/// to handle their keystrokes) and cannot type until they notice and fix
/// it manually. This happened during this feature's own POC development.
/// Reconciliation is keyed on THIS type's OWN persisted marker, never on
/// `GetGlobalEngine`'s live value — the POC measured that value reporting
/// `None` unreliably after a crash, so it cannot be trusted to detect one.
struct IBusCrashSafetyStateMachine {
  let store: any KeyValueStore

  /// **Must run before anything else** — the connection layer's very
  /// first substantive action after its two connections are up, before
  /// this app's own engine is ever registered or switched to. If the
  /// marker is non-empty, a previous run died mid-transaction: force-
  /// restores to the persisted engine name, then clears the marker ONLY
  /// if that restore call reports a CONFIRMED method-return (`setGlobalEngine`
  /// returns `true`). An unconfirmed/failed restore deliberately leaves
  /// the marker in place — the NEXT startup retries rather than silently
  /// giving up and leaving the user stuck on a dead engine.
  func reconcileAtStartup(setGlobalEngine: (String) -> Bool) {
    guard let pending = store.string(forKey: IBusEngineRestoreMarker.key), !pending.isEmpty else {
      return
    }
    guard setGlobalEngine(pending) else { return }
    store.set(nil, forKey: IBusEngineRestoreMarker.key)
  }

  /// Called immediately before switching the global engine to ours.
  /// Persists `previousEngineName` UNCONDITIONALLY (no confirmation to
  /// wait for — this is a local write, not a D-Bus round trip) so a crash
  /// any time between this call and a CONFIRMED `restoreAfterCommit`
  /// leaves a marker `reconcileAtStartup` can find on the next launch.
  func persistBeforeSwitch(previousEngineName: String) {
    store.set(previousEngineName, forKey: IBusEngineRestoreMarker.key)
  }

  /// Called after a commit attempt — REGARDLESS of whether that attempt
  /// found a live recipient — to restore the global engine back to
  /// `previousEngineName`. Clears the marker only if `setGlobalEngine`
  /// itself reports a CONFIRMED method-return; an unconfirmed/failed
  /// restore leaves the marker in place so `reconcileAtStartup` retries
  /// it on the next launch rather than silently abandoning the user on
  /// whatever engine this transaction left the session on.
  ///
  /// - Returns: whether the restore was confirmed (mirrors
  ///   `setGlobalEngine`'s own return) — purely informational for a
  ///   caller that wants to log it; this function's own marker-clearing
  ///   behavior does not need the caller to act on it.
  @discardableResult
  func restoreAfterCommit(previousEngineName: String, setGlobalEngine: (String) -> Bool) -> Bool {
    let confirmed = setGlobalEngine(previousEngineName)
    if confirmed {
      store.set(nil, forKey: IBusEngineRestoreMarker.key)
    }
    return confirmed
  }
}
