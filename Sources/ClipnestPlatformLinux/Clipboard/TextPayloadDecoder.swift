import Foundation

/// Decodes the raw bytes of a resolved text representation, per ICCCM's
/// per-target encoding rules — pure, no I/O.
public enum TextPayloadDecoder {
  /// Decodes `data`, using the encoding ICCCM/convention defines for
  /// `mimeType`:
  /// - `LinuxClipboardConstants.legacyStringAtomName` (`STRING`) is defined
  ///   by ICCCM section 2.6.2 as Latin-1 (ISO 8859-1) — the one target here
  ///   that is NOT UTF-8.
  /// - Every other entry in `LinuxClipboardConstants.textMimePriority`
  ///   (`text/plain;charset=utf-8`, `UTF8_STRING`, bare `text/plain`) is
  ///   UTF-8 in practice; a bare `text/plain` with no explicit charset is
  ///   treated as UTF-8, the universal modern-Linux default.
  ///
  /// Returns `nil` if `data` cannot be decoded under the chosen encoding.
  public static func decode(_ data: Data, mimeType: String) -> String? {
    if mimeType == LinuxClipboardConstants.legacyStringAtomName {
      return String(data: data, encoding: .isoLatin1)
    }
    return String(data: data, encoding: .utf8)
  }
}
