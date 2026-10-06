import Foundation

/// Presence-only, fail-closed detector for the Linux concealed-clipboard
/// markers (`LinuxClipboardConstants.privacyMarkerMimeTypes`) — the Linux
/// analogue of `PrivacyFilter`'s `org.nspasteboard.ConcealedType` check.
///
/// Deliberately takes only the `TARGETS` MIME-type-name list, never a
/// property VALUE: per this task's directive, a rejected copy's bytes must
/// never enter this process's address space, so the decision is made
/// entirely from target NAMES, before any `XConvertSelection` for an actual
/// payload is ever issued.
public enum PrivacyMarkerDetector {
  /// `true` iff any of `LinuxClipboardConstants.privacyMarkerMimeTypes` is
  /// present in `availableMimeTypes` — unconditional, no override.
  public static func isConcealed(mimeTypes availableMimeTypes: [String]) -> Bool {
    let available = Set(availableMimeTypes)
    return !LinuxClipboardConstants.privacyMarkerMimeTypes.isDisjoint(with: available)
  }
}
