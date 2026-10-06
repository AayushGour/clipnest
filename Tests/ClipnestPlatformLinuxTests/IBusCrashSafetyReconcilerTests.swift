// IBusCrashSafetyReconcilerTests.swift
//
// T-IBUS-CRASHWIRE: exercises `IBusCrashSafetyReconciler.restoreIfMarkerPresent`
// itself -- the orchestration THIS task adds around the already-exhaustively-
// tested `IBusCrashSafetyStateMachine` (`IBusCrashSafetyStateMachineTests
// .swift`) -- against inputs that deterministically never need a real
// socket: an empty `environment` makes `IBusAddressResolution
// .resolveWithDaemonPID` return `nil` WITHOUT any file or network I/O (see
// that type's own doc comment: "Pure decision logic only -- no socket I/O
// happens in this type"), so this suite can exercise the real
// resolve-fails / address-unresolved branch deterministically, in-process,
// with no daemon required.
//
// What this deliberately does NOT cover (manual-verify only, same
// convention as `IBusCommitClient`/`ShellHelperClient`): a REAL resolved
// address, connect, and `SetGlobalEngine` round trip against a live
// `ibus-daemon` -- see this task's return message for what was verified
// live on the project VM instead.

import ClipnestViewModels
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

/// Minimal in-memory `KeyValueStore` fake -- per-test-target private copy,
/// matching `IBusCrashSafetyStateMachineTests.swift`'s own documented
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

@Suite("IBusCrashSafetyReconciler (T-IBUS-CRASHWIRE)")
struct IBusCrashSafetyReconcilerTests {
  @Test(
    "restoreIfMarkerPresent is a true no-op when the store carries no marker -- IBusCrashSafetyStateMachine's own gate gets exercised THROUGH this wrapper, not bypassed by it"
  )
  func noopWhenNoMarkerPresent() {
    let store = FakeKeyValueStore()

    // Deliberately does NOT crash/hang even with a short timeout and no
    // real IBus reachable -- the marker gate short-circuits before any of
    // that matters.
    IBusCrashSafetyReconciler.restoreIfMarkerPresent(
      store: store, environment: [:], connectTimeout: .milliseconds(50),
      callTimeout: .milliseconds(50))

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == nil)
  }

  @Test(
    "restoreIfMarkerPresent LEAVES the marker in place when IBus's address cannot be resolved at all -- the real, deterministic case in this CI container (no ibus-daemon reachable), and the same 'never silently give up' contract IBusCrashSafetyStateMachine itself guarantees"
  )
  func leavesMarkerWhenAddressUnresolved() {
    let store = FakeKeyValueStore()
    store.set("xkb:us::eng", forKey: IBusEngineRestoreMarker.key)

    // No `IBUS_ADDRESS`, no `HOME`/`XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR` --
    // `IBusAddressResolution.resolveWithDaemonPID` returns `nil` with ZERO
    // file or socket I/O (verified by that type's own test suite), so this
    // exercises the real "address unresolved" branch inside this task's
    // new closure deterministically, not a timeout-dependent guess.
    IBusCrashSafetyReconciler.restoreIfMarkerPresent(
      store: store, environment: [:], connectTimeout: .milliseconds(50),
      callTimeout: .milliseconds(50))

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:us::eng")
  }

  @Test(
    "restoreIfMarkerPresent LEAVES the marker in place when IBUS_ADDRESS points at an address nothing is listening on -- the connect failure branch"
  )
  func leavesMarkerWhenConnectFails() {
    let store = FakeKeyValueStore()
    store.set("xkb:fr::fra", forKey: IBusEngineRestoreMarker.key)

    // A well-formed but nothing-is-listening address -- exercises the
    // "address resolved, connect failed" branch specifically (distinct
    // from the "address unresolved" branch above), still bounded by a
    // short `connectTimeout` so this test can't hang the suite.
    let environment = ["IBUS_ADDRESS": "unix:path=/tmp/clipnest-test-no-such-ibus-socket"]

    IBusCrashSafetyReconciler.restoreIfMarkerPresent(
      store: store, environment: environment, connectTimeout: .milliseconds(200),
      callTimeout: .milliseconds(200))

    #expect(store.string(forKey: IBusEngineRestoreMarker.key) == "xkb:fr::fra")
  }
}
