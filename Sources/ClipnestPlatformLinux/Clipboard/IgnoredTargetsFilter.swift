import Foundation

/// Strips the negotiation/bookkeeping target names
/// (`LinuxClipboardConstants.isIgnoredTarget`) out of a raw `TARGETS`
/// reply before it's cached/exposed — pure, no I/O.
///
/// Every category priority list in `LinuxClipboardConstants` only ever
/// names real content MIME types, so `MimeRepresentationSelector` would
/// never match one of these anyway; filtering them out here is defensive
/// (a bookkeeping atom's raw name is never handed to `PasteboardReader`,
/// even indirectly) and keeps `X11ClipboardConnection.currentTargets()`'s
/// cached list free of this task's explicitly-called-out noise (`TARGETS`,
/// `TIMESTAMP`, `MULTIPLE`, `SAVE_TARGETS`, `DELETE`, `_NETSCAPE_URL`,
/// `text/x-moz-url-priv`, any `application/x-qt-*`).
public enum IgnoredTargetsFilter {
  public static func filter(_ targetNames: [String]) -> [String] {
    targetNames.filter { !LinuxClipboardConstants.isIgnoredTarget($0) }
  }
}
