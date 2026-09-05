import ClipnestPlatformLinux
import Foundation

/// What this launch should do, decided from the bus's answer to
/// `RequestName(app.clipnest.Clipnest, DO_NOT_QUEUE)`.
///
/// `DO_NOT_QUEUE` is the whole mechanism: a second launch NEVER waits in
/// line for the name (the default, queueing behavior) — it finds out
/// immediately that another instance is running and gets out of the way.
public enum SingleInstanceDecision: Equatable, Sendable {
  /// This process now owns `app.clipnest.Clipnest` — proceed to build the
  /// composition root and start the control service for real.
  case becomePrimary
  /// Another instance already owns the name — forward this launch's
  /// argv to it (via `org.freedesktop.Application.Open`/`Activate` on the
  /// SAME well-known name) and exit `0` without building anything.
  case forwardToRunningInstance
  /// The bus itself refused/errored (no session bus reachable, timeout,
  /// `RequestName` call failed outright) — neither a clean "I'm primary"
  /// nor a clean "someone else is" answer. The caller treats this as
  /// "run anyway, standalone" rather than refusing to start the app just
  /// because the control surface couldn't be secured — a broken/absent
  /// session bus should degrade the app, not prevent it from launching.
  case busUnavailable

  /// Pure decision from `RequestName`'s reply code — see
  /// `DBusRequestNameReply`'s doc comment for what each code means.
  /// `nil` (the call errored, timed out, or the reply body didn't parse)
  /// maps to `.busUnavailable`. Not `public` — `DBusRequestNameReply` is
  /// `internal`, and nothing outside this module ever calls this directly
  /// (only `SingleInstance.acquire`, in the same module); `@testable
  /// import` still reaches it for `SingleInstanceDecisionTests`.
  static func decide(requestNameReply: DBusRequestNameReply?) -> SingleInstanceDecision {
    switch requestNameReply {
    case .primaryOwner: return .becomePrimary
    case .alreadyOwner: return .becomePrimary
    case .inQueue, .exists: return .forwardToRunningInstance
    case nil: return .busUnavailable
    }
  }
}

/// Real, bus-connected single-instance acquisition + argv forwarding.
/// Wraps the pure `SingleInstanceDecision.decide` with the actual `Hello`/
/// `RequestName`/`Open` calls — manual-verify only (needs a real session
/// bus), same "pure decision extracted, real I/O kept thin and separate"
/// split as every other D-Bus-driven type in this module.
enum SingleInstance {
  /// Sends `Hello` (required before any other traffic — see
  /// `DBusStandardRequests.hello`'s doc comment) then
  /// `RequestName(app.clipnest.Clipnest, DO_NOT_QUEUE)`, and returns the
  /// resulting decision.
  static func acquire(on connection: any DBusCalling, timeout: Duration) -> SingleInstanceDecision {
    guard connection.call(DBusStandardRequests.hello(serial: 1), timeout: timeout) != nil else {
      return .busUnavailable
    }
    let reply = connection.call(
      DBusStandardRequests.requestName(
        ClipnestControlName.busName, flags: DBusRequestNameFlag.doNotQueue, serial: 2),
      timeout: timeout)
    let code = reply.flatMap(DBusStandardResponses.parseRequestNameReply)
    return SingleInstanceDecision.decide(requestNameReply: code)
  }

  /// Forwards this launch's `arguments` (typically `CommandLine.arguments
  /// .dropFirst()`) to the already-running instance via
  /// `org.freedesktop.Application.Open` when there's at least one path-like
  /// argument, else a bare `Activate` — mirroring how a compositor/shell
  /// would D-Bus-activate this app itself. Fire-and-forget: the caller
  /// exits immediately after regardless of whether the running instance
  /// actually acts on it, matching every desktop app's "second launch is a
  /// no-op besides waking the first" convention.
  static func forwardArguments(_ arguments: [String], on connection: any DBusCalling) {
    let message: DBusMessage
    if arguments.isEmpty {
      message = DBusMessage(
        type: .methodCall, serial: connection.allocateSerialOrFallback(),
        path: ClipnestControlName.objectPath,
        interface: FreedesktopApplicationName.interface,
        member: FreedesktopApplicationMember.activate,
        destination: ClipnestControlName.busName, body: [.array([])])
    } else {
      message = DBusMessage(
        type: .methodCall, serial: connection.allocateSerialOrFallback(),
        path: ClipnestControlName.objectPath,
        interface: FreedesktopApplicationName.interface,
        member: FreedesktopApplicationMember.open,
        destination: ClipnestControlName.busName,
        body: [.array(arguments.map(DBusValue.string)), .array([])])
    }
    _ = connection.call(message, timeout: .milliseconds(500))
  }
}

extension DBusCalling {
  /// `DBusCalling` only exposes `call(_:timeout:)`, not serial allocation
  /// (that's `DBusConnection`'s own concern, and the fake this module's
  /// tests use has no serial counter at all) — real callers always have a
  /// real `DBusConnection` in hand and should call `allocateSerial()`
  /// directly; this fallback (a fixed, spec-legal non-zero serial) only
  /// exists so `SingleInstance.forwardArguments` can be written against
  /// the narrow `DBusCalling` seam without every test double implementing
  /// serial bookkeeping it doesn't need.
  fileprivate func allocateSerialOrFallback() -> UInt32 {
    (self as? DBusConnection)?.allocateSerial() ?? 1
  }
}
