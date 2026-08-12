import AppKit
import Foundation

/// Abstraction over `NSPasteboard` so `PasteboardReader` (and anything that polls
/// it, e.g. `ClipboardMonitor`) can be exercised in tests without touching the
/// real system pasteboard.
public protocol PasteboardReading {
  /// The pasteboard types currently available, in the pasteboard's own priority order.
  var availableTypes: [NSPasteboard.PasteboardType] { get }

  /// Reads string data for a given type, if present.
  func string(forType type: NSPasteboard.PasteboardType) -> String?

  /// Reads raw data for a given type, if present.
  func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: PasteboardReading {
  public var availableTypes: [NSPasteboard.PasteboardType] {
    types ?? []
  }
}

/// Classifies pasteboard content into an `ItemKind` and extracts the preview
/// text, a stable content hash, and the payload's byte size.
public struct PasteboardReader: Sendable {
  /// The result of classifying a pasteboard's current content.
  ///
  /// `rawData` is populated only for kinds whose bytes must be persisted to
  /// `BlobStore` (currently `.image` and `.richText`). `PasteboardReader` deliberately never
  /// touches `BlobStore` itself — it stays a pure, I/O-free classifier;
  /// `ClipboardMonitor` owns writing `rawData` to `BlobStore` and setting the
  /// resulting `ClipItem.blobPath` (see project-context.md decision D8: this
  /// keeps "classify" and "persist" as separate responsibilities, and keeps
  /// classification tests filesystem-free). `fileURL` is populated only for
  /// `.file`, so the paste path can re-offer the original file reference.
  public struct Classification: Sendable {
    public var kind: ItemKind
    public var previewText: String
    public var contentHash: String
    public var byteSize: Int
    public var rawData: Data?
    public var fileURL: URL?

    public init(
      kind: ItemKind,
      previewText: String,
      contentHash: String,
      byteSize: Int,
      rawData: Data? = nil,
      fileURL: URL? = nil
    ) {
      self.kind = kind
      self.previewText = previewText
      self.contentHash = contentHash
      self.byteSize = byteSize
      self.rawData = rawData
      self.fileURL = fileURL
    }
  }

  private static let validLinkSchemes: Set<String> = ["http", "https", "ftp", "mailto"]

  /// Pasteboard types checked for image bytes, in priority order. Both are
  /// checked (not just one) because different apps offer different image
  /// representations — e.g. Preview typically offers `.tiff`, many web/image
  /// apps offer `.png`.
  private static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]

  public init() {}

  /// Reads and classifies the current contents of `pasteboard`.
  ///
  /// Type-priority order is `.fileURL` → image (`.tiff`/`.png`) → `.rtf` →
  /// `.string`, most-specific first. This matters because a single pasteboard
  /// change commonly carries multiple representations at once — e.g. a
  /// Finder file copy often also carries a `.tiff` icon thumbnail and/or a
  /// plain-text path string, and a browser image copy often also carries a
  /// `.string` URL — so a generic type must never win over a more specific
  /// one that's also present.
  ///
  /// Returns `nil` when the pasteboard holds no content this reader
  /// currently understands.
  public func read(from pasteboard: PasteboardReading) -> Classification? {
    let types = pasteboard.availableTypes

    if types.contains(.fileURL), let urlString = pasteboard.string(forType: .fileURL) {
      return readFile(urlString)
    }

    if let imageData = firstAvailableImageData(from: pasteboard, types: types) {
      return readImage(imageData)
    }

    if types.contains(.rtf), let rtfData = pasteboard.data(forType: .rtf) {
      return readRichText(rtfData, from: pasteboard)
    }

    if types.contains(.string), let text = pasteboard.string(forType: .string) {
      return readPlainText(text)
    }

    return nil
  }

  private func firstAvailableImageData(
    from pasteboard: PasteboardReading,
    types: [NSPasteboard.PasteboardType]
  ) -> Data? {
    for type in Self.imagePasteboardTypes where types.contains(type) {
      if let data = pasteboard.data(forType: type) { return data }
    }
    return nil
  }

  private func readImage(_ data: Data) -> Classification {
    Classification(
      kind: .image,
      previewText: imagePreviewText(for: data),
      contentHash: BlobStore.contentHash(of: data),
      byteSize: data.count,
      rawData: data
    )
  }

  private func imagePreviewText(for data: Data) -> String {
    if let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
      return "Image, \(rep.pixelsWide)\u{00D7}\(rep.pixelsHigh)"
    }
    return "Image (\(formattedByteCount(data.count)))"
  }

  private func formattedByteCount(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }

  private func readFile(_ urlString: String) -> Classification {
    let url = URL(string: urlString)
    let filename = (url?.isFileURL == true ? url?.lastPathComponent : nil) ?? urlString
    // `byteSize` is deliberately 0 here: reading the real file's size
    // (`attributesOfItem`) ran synchronously on the `@MainActor` capture path
    // (`ClipboardMonitor.checkNow`, driven by the poll `Timer`), and for
    // iCloud/dataless or TCC-gated files that `stat` blocked the main thread
    // for seconds — the actual cause of the "file hover" freeze. The size is
    // read later, off the main thread, only when a preview needs it.
    return Classification(
      kind: .file,
      previewText: filename,
      contentHash: BlobStore.contentHash(of: Data(urlString.utf8)),
      byteSize: 0,
      fileURL: url
    )
  }

  private func readRichText(
    _ rtfData: Data,
    from pasteboard: PasteboardReading
  ) -> Classification {
    let previewText = plainTextPreview(forRTF: rtfData, fallbackFrom: pasteboard)
    return Classification(
      kind: .richText,
      previewText: previewText,
      contentHash: BlobStore.contentHash(of: rtfData),
      byteSize: rtfData.count,
      rawData: rtfData
    )
  }

  private func plainTextPreview(forRTF rtfData: Data, fallbackFrom pasteboard: PasteboardReading)
    -> String
  {
    if let plainString = pasteboard.string(forType: .string) {
      return plainString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let attributed = try? NSAttributedString(
      data: rtfData,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    ) {
      return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "Rich Text"
  }

  private func readPlainText(_ text: String) -> Classification {
    let previewText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = Data(text.utf8)
    let kind: ItemKind = isLink(previewText) ? .link : .text
    return Classification(
      kind: kind,
      previewText: previewText,
      contentHash: BlobStore.contentHash(of: data),
      byteSize: data.count
    )
  }

  private func isLink(_ text: String) -> Bool {
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
      return false
    }
    guard Self.validLinkSchemes.contains(scheme) else { return false }
    if scheme == "mailto" { return true }
    return !(url.host?.isEmpty ?? true)
  }
}
