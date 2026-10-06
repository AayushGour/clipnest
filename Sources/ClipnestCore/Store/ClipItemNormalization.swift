import Foundation

/// The single derivation rule for a `ClipItem`'s search-normalized text —
/// `previewText` plus, once recognized, `ocrText` (so a screenshot becomes
/// findable by its recognized contents too), lowercased.
///
/// Platform-neutral: pure `Foundation`, no `SwiftData` dependency. Extracted
/// out of `SwiftDataClipStore.swift` (where this derivation originated, as
/// `ClipItemRecord.computeNormalizedText(previewText:ocrText:)`) specifically
/// so the Linux port's future SQLite-backed `ClipStore` can reuse this exact
/// function instead of reimplementing it and risking drift between the two
/// backing stores — coding-standards.md's DRY rule.
///
/// `ClipItemRecord.computeNormalizedText(previewText:ocrText:)` is now a
/// one-line forwarder to this function; every existing call site
/// (`ClipItemRecord.init(_ item:)`, `SwiftDataClipStore
/// .backfillNormalizedText(in:)`, and `SwiftDataClipStore
/// .setRecognizedText(_:text:)`) is unchanged — same inputs, same outputs.
public enum ClipItemNormalization {
  /// - Parameters:
  ///   - previewText: The item's plain preview text — always included.
  ///   - ocrText: The item's recognized (OCR) text, if any. `nil` or empty
  ///     is treated identically to "not yet recognized."
  /// - Returns: `previewText` lowercased when `ocrText` is `nil`/empty;
  ///   otherwise `previewText` and `ocrText` joined by a newline, lowercased.
  public static func computeNormalizedText(previewText: String, ocrText: String?) -> String {
    guard let ocrText, !ocrText.isEmpty else { return previewText.lowercased() }
    return "\(previewText)\n\(ocrText)".lowercased()
  }
}
