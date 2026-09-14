// IBusCrashSafetyStateMachineTests.swift
//
// T-IBUS-CLIENT: exhaustive coverage of D-IBUS-3's persist-before-switch /
// clear-after-confirmed-restore / reconcile-at-startup state machine —
// against a fully in-memory fake `KeyValueStore` and fake "call
// SetGlobalEngine" closures, per this task's own brief. No `DBusConnection`,
// no real filesystem, no real bus.

import ClipnestViewModels
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

/// Minimal in-memory `KeyValueStore` fake — per-test-target private copy,
/// matching `LinuxClipboardSelectionReplacerTests.swift`'s own documented
/// precedent ("per-test-target private fakes, not a shared test-only
/// product").
private final class FakeKeyValueStore: KeyValueStore, @unchecked Sendable {
  private var storage: [String: Any] = [:]

  func object(forKey key: String) -> Any? { storage[key] }
  func string(forKey key: String) -> String? { storage[key] as? String }
  func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
  func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
  func set(_ value: Any?, forKey key: String) {
    if let value {
      storage[key] = value
    } else {
      storage.removeValue(forKey: key)
    }
  }
}

@Suite("IBusCrashSafetyStateMachine (D-IBUS-3)")
struct IBusCrashSafetyStateMachineTests {
  // MARK: - persistBeforeSwitch

  @Test("persistBeforeSwitch writes the previous engine name under the marker key")
  func persistBeforeSwitchWritesMarker() {
    let store = FakeKeyValueStore()
    let machine = IBusCrashSafetyStateMachine(store: store)

    machine.persistBeforeSwitch(previousEngineName: "xkb:us::eng")

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:us::eng")
  }

  @Test("persistBeforeSwitch overwrites a stale marker from an earlier transaction")
  func persistBeforeSwitchOverwritesStaleMarker() {
    let store = FakeKeyValueStore()
    store.set("some-stale-value", forKey: IBusEngineRestoreMarker.key)
    let machine = IBusCrashSafetyStateMachine(store: store)

    machine.persistBeforeSwitch(previousEngineName: "xkb:fr::fra")

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:fr::fra")
  }

  // MARK: - restoreAfterCommit

  @Test("restoreAfterCommit clears the marker when setGlobalEngine reports CONFIRMED")
  func restoreAfterCommitClearsMarkerOnConfirmed() {
    let store = FakeKeyValueStore()
    let machine = IBusCrashSafetyStateMachine(store: store)
    machine.persistBeforeSwitch(previousEngineName: "xkb:us::eng")

    let confirmed = machine.restoreAfterCommit(previousEngineName: "xkb:us::eng") { name in
      #expect(name == "xkb:us::eng")
      return true
    }

    #expect(confirmed)
    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == nil)
  }

  @Test(
    "restoreAfterCommit LEAVES the marker in place when setGlobalEngine reports UNCONFIRMED — the whole point of the crash-safety design"
  )
  func restoreAfterCommitLeavesMarkerOnUnconfirmed() {
    let store = FakeKeyValueStore()
    let machine = IBusCrashSafetyStateMachine(store: store)
    machine.persistBeforeSwitch(previousEngineName: "xkb:us::eng")

    let confirmed = machine.restoreAfterCommit(previousEngineName: "xkb:us::eng") { _ in false }

    #expect(!confirmed)
    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:us::eng")
  }

  // MARK: - reconcileAtStartup

  @Test("reconcileAtStartup is a no-op — never calls setGlobalEngine — when no marker is present")
  func reconcileAtStartupNoopWhenNoMarker() {
    let store = FakeKeyValueStore()
    let machine = IBusCrashSafetyStateMachine(store: store)
    var callCount = 0

    machine.reconcileAtStartup { _ in
      callCount += 1
      return true
    }

    #expect(callCount == 0)
  }

  @Test(
    "reconcileAtStartup treats an empty-string marker as absent, same as reconcileAtStartup's own 'no marker' contract"
  )
  func reconcileAtStartupTreatsEmptyMarkerAsAbsent() {
    let store = FakeKeyValueStore()
    store.set("", forKey: IBusEngineRestoreMarker.key)
    let machine = IBusCrashSafetyStateMachine(store: store)
    var callCount = 0

    machine.reconcileAtStartup { _ in
      callCount += 1
      return true
    }

    #expect(callCount == 0)
  }

  @Test(
    "reconcileAtStartup force-restores to the persisted engine and clears the marker on a CONFIRMED restore — this is the crash-recovery path"
  )
  func reconcileAtStartupRestoresAndClearsOnConfirmed() {
    let store = FakeKeyValueStore()
    store.set("xkb:us::eng", forKey: IBusEngineRestoreMarker.key)
    let machine = IBusCrashSafetyStateMachine(store: store)
    var calledWith: String?

    machine.reconcileAtStartup { name in
      calledWith = name
      return true
    }

    #expect(calledWith == "xkb:us::eng")
    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == nil)
  }

  @Test(
    "reconcileAtStartup LEAVES the marker in place on an UNCONFIRMED restore, so the NEXT startup retries rather than silently giving up"
  )
  func reconcileAtStartupLeavesMarkerOnUnconfirmedRestore() {
    let store = FakeKeyValueStore()
    store.set("xkb:us::eng", forKey: IBusEngineRestoreMarker.key)
    let machine = IBusCrashSafetyStateMachine(store: store)

    machine.reconcileAtStartup { _ in false }

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:us::eng")
  }

  // MARK: - Full lifecycle round trips

  @Test(
    "A normal transaction (persist -> confirmed restore) leaves nothing for the next startup's reconciliation to find"
  )
  func normalTransactionLeavesNoMarkerForReconciliation() {
    let store = FakeKeyValueStore()
    let machine = IBusCrashSafetyStateMachine(store: store)

    machine.persistBeforeSwitch(previousEngineName: "xkb:us::eng")
    machine.restoreAfterCommit(previousEngineName: "xkb:us::eng") { _ in true }

    // A fresh state machine over the SAME store, simulating the next
    // process launch — reconciliation must be a true no-op.
    let nextLaunch = IBusCrashSafetyStateMachine(store: store)
    var callCount = 0
    nextLaunch.reconcileAtStartup { _ in
      callCount += 1
      return true
    }
    #expect(callCount == 0)
  }

  @Test(
    "A crash between persist and restore (no restoreAfterCommit ever runs) is repaired by the NEXT startup's reconciliation — this is the core user-facing guarantee (D-IBUS-3): the user is never left on a dead engine"
  )
  func crashBetweenPersistAndRestoreIsRepairedByReconciliation() {
    let store = FakeKeyValueStore()
    let diedMidTransaction = IBusCrashSafetyStateMachine(store: store)
    diedMidTransaction.persistBeforeSwitch(previousEngineName: "xkb:fr::fra")
    // Process dies here -- restoreAfterCommit never runs.

    let nextLaunch = IBusCrashSafetyStateMachine(store: store)
    var calledWith: String?
    nextLaunch.reconcileAtStartup { name in
      calledWith = name
      return true
    }

    #expect(calledWith == "xkb:fr::fra")
    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == nil)
  }

  @Test(
    "restoreAfterCommit's return value mirrors the setGlobalEngine closure's own return, for a caller that wants to log it"
  )
  func restoreAfterCommitReturnValueMirrorsClosure() {
    let store = FakeKeyValueStore()
    let machine = IBusCrashSafetyStateMachine(store: store)
    #expect(machine.restoreAfterCommit(previousEngineName: "x") { _ in true } == true)
    #expect(machine.restoreAfterCommit(previousEngineName: "x") { _ in false } == false)
  }
}
