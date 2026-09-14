// IBusDaemonLiveness.swift
//
// The connection layer's one process-liveness syscall (`kill(pid, 0)`) —
// shared by `IBusCommitClient.resolveAndConnect` and
// `IBusCrashSafetyReconciler.restoreIfMarkerPresent`, both of which gate a
// resolved `IBusResolvedAddress` on the identical fact: is the daemon PID
// named in its socket-address file still alive (T-IBUS-PIDLIVE). Lives here,
// not `ClipnestPlatformLinux/InputMethod/IBusAddress.swift` — that module's
// own top doc comment states a real process-liveness syscall is deliberately
// out of scope for its pure, no-socket-I/O logic; the connection layer
// (this module) is where that check has always belonged.
//
// Previously two copies, deliberately and disclosed: T-IBUS-CRASHWIRE
// (`IBusCrashSafetyReconciler.swift`) and T-IBUS-REPLACER
// (`IBusCommitClient.swift`) were built concurrently in the same session,
// and keeping each file's edit footprint at zero on the OTHER avoided a
// shared-file collision mid-flight while both were still moving. Both have
// landed now — folded into this one shared helper (reviewer pass) so
// "is the IBus daemon PID alive" has exactly one implementation.
import Foundation

#if canImport(Glibc)
  import Glibc
#endif

enum IBusDaemonLiveness {
  #if canImport(Glibc)
    /// `kill(pid, 0)` — sends no signal, just probes whether `pid` is a live
    /// process this user can see; matches upstream `ibus_get_address()`'s
    /// own liveness gate exactly (T-IBUS-PIDLIVE).
    static func isDaemonProcessAlive(pid: Int32) -> Bool {
      Glibc.kill(pid, 0) == 0
    }
  #else
    static func isDaemonProcessAlive(pid: Int32) -> Bool { false }
  #endif
}
