import Foundation

/// A narrow protocol carved out of `IBusCommitClient`'s one real entry
/// point, purely as a testability seam — mirrors `DBusCalling`'s identical
/// role for `DBusConnection` (a `final class` owning a live socket, whose
/// tests fake the seam rather than the class). `LinuxIBusSelectionReplacer`
/// (T-IBUS-REPLACER) depends on `any IBusReplacing`, not the concrete
/// `IBusCommitClient`, so `LinuxIBusSelectionReplacerTests` can exercise its
/// `IBusCommitOutcome` -> `ClipnestCore.SelectionReplaceResult` mapping and
/// its `IBusCommitPolicy` gate with a fully in-memory fake — no real
/// `ibus-daemon`, matching every other "manual-verify only" live-I/O type
/// in this codebase.
protocol IBusReplacing: Sendable {
  /// `sending`, not `@Sendable`: the real caller
  /// (`LinuxIBusSelectionReplacer`, `@MainActor` via `SelectionReplacing`)
  /// forwards a closure it received as a PLAIN, non-`Sendable` parameter
  /// (`ClipnestCore.SelectionReplacing`'s own signature, which this task
  /// does not touch beyond adding `.committedUnconfirmed`) straight
  /// through with no further use afterward — `sending` lets the compiler
  /// verify that ownership transfer at the call site instead of requiring
  /// the closure TYPE itself to be `Sendable`, which `SelectionReplacing`
  /// never declares.
  func replaceSelection(bodyForSelection: sending @escaping (String) async -> String?) async
    -> IBusCommitOutcome
}

extension IBusCommitClient: IBusReplacing {}
