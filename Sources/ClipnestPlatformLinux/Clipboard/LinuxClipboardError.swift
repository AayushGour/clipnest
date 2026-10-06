import Foundation

/// Errors surfaced by the Linux X11 clipboard backend — per-module `Error`
/// enum, matching `.claude/coding-standards.md`'s error-handling pattern
/// (`ClipStoreError`, `BlobStoreError`, etc.).
///
/// `LinuxPasteboard`/`LinuxFrontmostApplicationProvider` themselves never
/// throw these — `PasteboardReading`/`FrontmostApplicationProviding` are
/// non-throwing protocols (see `ClipnestCore`), so every failure degrades
/// to `nil`, matching those protocols' existing contract. These cases exist
/// for `X11ClipboardConnection`'s own internal use and for tests that
/// exercise the connection protocols' failure paths via a fake.
public enum LinuxClipboardError: Error, Equatable, Sendable {
  /// `XOpenDisplay` failed — no X server reachable (no `DISPLAY`, or the
  /// compositor/Xwayland isn't running).
  case displayConnectionFailed
  /// Creating this backend's own `InputOnly` watcher window failed.
  case watcherWindowCreationFailed
  /// `XConvertSelection` for `mimeType` never produced a `SelectionNotify`
  /// reply (the owner refused, or vanished) within a reasonable wait.
  case selectionConversionFailed(mimeType: String)
  /// The INCR transfer for `mimeType` failed — see `IncrTransferError` for
  /// the specific reason (timeout vs. size ceiling).
  case incrTransferFailed(mimeType: String, underlying: IncrTransferError)
}
