import Foundation

/// P2-A (Linux port): the non-Apple default `RichTextFlattening`
/// conformance — see that protocol's doc comment. Always returns `nil`,
/// which is an already-handled fallback for `PasteboardReader.
/// plainTextPreview(forRTF:fallbackPlainText:)` (it falls back to
/// `fallbackPlainText` or the literal `"Rich Text"` placeholder), not a new
/// failure mode.
///
/// The Linux port's own rich-text pasteboard representation is `text/html`,
/// not RTF, so a real non-Apple conformance would flatten HTML rather than
/// parse RTF — that backend is a follow-up task, not this one. "Never used
/// in production" once that backend lands and is wired into
/// `PlatformDefaults.richTextFlattener`'s non-macOS branch instead, mirroring
/// this file's own `PlatformDefaults.swift` doc comment's convention for
/// portable no-op defaults.
public struct NullRichTextFlattener: RichTextFlattening {
  public init() {}

  public func plainText(fromRTF data: Data) -> String? {
    nil
  }
}
