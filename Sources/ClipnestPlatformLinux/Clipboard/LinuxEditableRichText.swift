import ClipnestCore
import Foundation

/// Linux bridge between a stored rich-text blob and the editor's styled runs.
///
/// The blob is a `LinuxRichTextBundle` (or, for items captured by old builds,
/// raw flat `text/html`). Loading reads only the `text/html` representation;
/// saving regenerates a bundle holding exactly one freshly generated
/// `text/html` representation — no stale RTF survives next to edited HTML — and
/// that bundle pastes through `GTKClipboardWriting.representationsToPublish`
/// unchanged.
public enum LinuxEditableRichText {
  private enum Legacy {
    static let bundleMagic = Data("CNR1".utf8)
    static let rtfMagic = Data("{\\rtf".utf8)
  }

  /// As `load(blob:plainText:)`, but a rich item whose blob is missing or
  /// unreadable (`richContentMissing`) is flagged lossy: it opens as plain text
  /// and saving would drop the formatting it had.
  public static func load(blob: Data?, plainText: String, richContentMissing: Bool)
    -> EditableRichText
  {
    var loaded = load(blob: blob, plainText: plainText)
    if richContentMissing { loaded.isLossy = true }
    return loaded
  }

  /// Opens `blob` for editing. Total: anything unreadable (missing HTML,
  /// corrupt bundle, invalid UTF-8, oversized or too deeply nested HTML)
  /// falls back to one plain run of `plainText`, flagged lossy.
  public static func load(blob: Data?, plainText: String) -> EditableRichText {
    guard let blob else {
      return EditableRichText(runs: [StyledRun(text: plainText)], isLossy: false)
    }
    guard let html = htmlString(from: blob) else { return plainFallback(plainText) }
    let parsed = HTMLStyledRunCodec.parse(html: html)
    guard parsed.runs.contains(where: { !$0.text.isEmpty }) else {
      return plainFallback(plainText)
    }
    let roundTrips =
      HTMLStyledRunCodec.parse(html: HTMLStyledRunCodec.html(from: parsed.runs))
      .runs == parsed.runs
    return EditableRichText(
      runs: parsed.runs, isLossy: parsed.hasUnsupportedContent || !roundTrips)
  }

  /// A bundle with ONE regenerated `text/html` representation.
  public static func blob(from runs: [StyledRun]) -> Data {
    LinuxRichTextBundle(representations: [
      .init(
        mimeType: LinuxClipboardConstants.htmlMimeType,
        data: Data(HTMLStyledRunCodec.html(from: runs).utf8))
    ]).encode()
  }

  private static func plainFallback(_ plainText: String) -> EditableRichText {
    EditableRichText(runs: [StyledRun(text: plainText)], isLossy: !plainText.isEmpty)
  }

  /// The HTML text of `blob`, or nil if it has none (RTF-only bundle, corrupt
  /// bundle, RTF-looking legacy bytes, invalid UTF-8, or over the size limit).
  private static func htmlString(from blob: Data) -> String? {
    let payload: Data
    if let bundle = LinuxRichTextBundle.decode(blob) {
      guard
        let html = bundle.representations.first(where: {
          $0.mimeType.lowercased().hasPrefix(LinuxClipboardConstants.htmlMimeType)
        })
      else { return nil }
      payload = html.data
    } else if blob.starts(with: Legacy.bundleMagic) || blob.starts(with: Legacy.rtfMagic) {
      return nil
    } else {
      payload = blob
    }
    guard payload.count <= HTMLStyledRunCodec.maxInputBytes else { return nil }
    return String(data: payload, encoding: .utf8)
  }
}
