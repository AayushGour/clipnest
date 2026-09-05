import Foundation

#if os(macOS)
  import AppKit

  /// Production `RichTextFlattening` conformance — the exact
  /// `NSAttributedString`-backed body `PasteboardReader
  /// .plainTextPreview(forRTF:fallbackPlainText:)` used to run inline,
  /// extracted verbatim behind the protocol seam by the Linux port (P2-A)
  /// so macOS behavior stays byte-identical (frozen per D47) while the
  /// shared file compiles without `AppKit` elsewhere.
  public struct MacRichTextFlattener: RichTextFlattening {
    public init() {}

    public func plainText(fromRTF data: Data) -> String? {
      guard
        let attributed = try? NSAttributedString(
          data: data,
          options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil
        )
      else {
        return nil
      }
      return attributed.string
    }
  }

  extension PlatformDefaults {
    /// macOS's `RichTextFlattening` default — `NSAttributedString`-backed,
    /// byte-identical to the code this replaced. See `MacRichTextFlattener`.
    public static var richTextFlattener: any RichTextFlattening {
      MacRichTextFlattener()
    }
  }
#else
  extension PlatformDefaults {
    /// The non-Apple `RichTextFlattening` default. See
    /// `NullRichTextFlattener`'s doc comment.
    public static var richTextFlattener: any RichTextFlattening {
      NullRichTextFlattener()
    }
  }
#endif
