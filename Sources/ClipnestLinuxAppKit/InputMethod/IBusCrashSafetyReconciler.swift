// IBusCrashSafetyReconciler.swift
//
// T-IBUS-CRASHWIRE: wires `IBusCrashSafetyStateMachine` (D-IBUS-3) to the
// PROCESS lifecycle, independent of whether a real, commit-capable
// `IBusCommitClient` exists yet this session. See `ProcessSignalShutdown
// .swift` (`App/`) for the SIGTERM/SIGINT half of this task; this type is
// the ONE routine `LinuxAppLifecycle.launch`'s startup reconciliation, the
// SIGTERM/SIGINT self-pipe dispatch, AND the tray's "Quit" item all call —
// so all three funnel through the same place and can never drift apart
// (this task's own brief).
//
// Deliberately NOT `IBusCommitClient.resolveAndConnect()` + `.start()`:
// reconciliation only ever needs to ISSUE `SetGlobalEngine` once, when a
// marker is genuinely pending — never register a component, create an
// engine, or run a reader thread. `resolveAndConnect()` does all of that
// and hands back a live object meant to survive for the app's whole
// session; calling it here — before `LinuxAppEnvironment` (T-IBUS-REPLACER,
// which owns the REAL, long-lived `IBusCommitClient`) even exists — would
// register a SECOND `clipnest-snippet` component/engine and leak its
// reader thread the instant this function returned, with nothing left to
// ever stop it. This type opens exactly one short-lived connection and
// leaves nothing running behind it.
//
// Daemon-PID liveness (`kill(pid, 0)`) is `IBusDaemonLiveness`
// (`IBusDaemonLiveness.swift`, this directory) — shared with
// `IBusCommitClient.resolveAndConnect`, not a second copy. See that file's
// own doc comment for why the two used to be deliberate, disclosed
// duplicates (concurrent edits by T-IBUS-CRASHWIRE and T-IBUS-REPLACER in
// the same session) and why folding them back together only became safe
// once both landed.
import ClipnestCore
import ClipnestPlatformLinux
import ClipnestViewModels
import Foundation

enum IBusCrashSafetyReconciler {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "IBusCrashSafetyReconciler")

  /// Restores the global IBus engine if — and only if —
  /// `IBusCrashSafetyStateMachine`'s own persisted marker (keyed on
  /// `store`) shows a previous transaction never confirmed its restore.
  /// The marker check itself is pure and in-memory
  /// (`IBusCrashSafetyStateMachine.reconcileAtStartup` reads it FIRST) —
  /// the closure below, the only place this function touches the network,
  /// is invoked ONLY when a marker is genuinely present. The
  /// overwhelmingly common case (a healthy quit, or a startup with nothing
  /// pending) therefore never resolves an address, opens a socket, or
  /// blocks on anything.
  ///
  /// Never crashes or throws. Every failure along the resolve/connect/call
  /// chain (no address, a dead daemon PID, a failed connect, a timed-out
  /// or unconfirmed `SetGlobalEngine`) degrades to a logged no-op with the
  /// marker deliberately left in place — matching
  /// `IBusCrashSafetyStateMachine`'s own "never silently give up on a
  /// dangling marker" contract: the NEXT call (the next process launch, or
  /// the next quit attempt) retries instead of losing track of it.
  static func restoreIfMarkerPresent(
    store: any KeyValueStore,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    connectTimeout: Duration = IBusCommitClient.defaultConnectTimeout,
    callTimeout: Duration = IBusCommitClient.defaultCallTimeout
  ) {
    let crashSafety = IBusCrashSafetyStateMachine(store: store)
    crashSafety.reconcileAtStartup { name in
      let readFile: (String) -> String? = { path in
        try? String(contentsOfFile: path, encoding: .utf8)
      }
      guard
        let resolved = IBusAddressResolution.resolveWithDaemonPID(
          environment: environment, readFile: readFile)
      else {
        logger.notice("restoreIfMarkerPresent: IBus address unresolved, marker left in place")
        return false
      }
      if let daemonPID = resolved.daemonPID,
        !IBusDaemonLiveness.isDaemonProcessAlive(pid: daemonPID)
      {
        logger.notice(
          "restoreIfMarkerPresent: stale socket-address file, daemon pid \(daemonPID) is dead, marker left in place"
        )
        return false
      }
      guard
        let connection = DBusConnection.connect(address: resolved.address, timeout: connectTimeout)
      else {
        logger.notice("restoreIfMarkerPresent: could not connect to IBus, marker left in place")
        return false
      }
      guard
        let reply = connection.call(
          IBusRequests.setGlobalEngine(name: name, serial: 1), timeout: callTimeout)
      else {
        logger.notice("restoreIfMarkerPresent: SetGlobalEngine got no reply, marker left in place")
        return false
      }
      let confirmed = IBusResponses.isSuccessReply(reply)
      logger.notice(
        "restoreIfMarkerPresent: restored previous global engine, confirmed=\(confirmed)")
      return confirmed
    }
  }
}
