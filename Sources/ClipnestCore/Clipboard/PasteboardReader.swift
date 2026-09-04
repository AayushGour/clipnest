import AppKit
import Foundation
import ImageIO

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

  /// T-PERF1: the bytes/strings `pullRawPayload(from:)` fetched for whichever
  /// single type-priority branch matched — one case per branch `read(from:)`
  /// used to resolve in a single pass. `classify(_:)` turns this into a
  /// `Classification` doing pure CPU work only (no further `PasteboardReading`
  /// access), so a caller can fetch on `@MainActor` (required — this is real
  /// `NSPasteboard` I/O) and classify on a background task. `Sendable` so it
  /// can cross that boundary. Each case mirrors exactly what its `read(from:)`
  /// branch used to read inline, so `pullRawPayload` + `classify` together
  /// produce byte-identical results to the old single-pass `read(from:)` —
  /// see `PasteboardReaderTests`, still driven through `read(from:)` alone,
  /// unchanged.
  public enum RawPayload: Sendable {
    case file(urlString: String)
    case image(Data)
    case richText(rtf: Data, fallbackPlainText: String?)
    case plainText(String)
  }

  public init() {}

  /// Reads and classifies the current contents of `pasteboard` in one call —
  /// equivalent to `pullRawPayload(from:)` immediately followed by
  /// `classify(_:)`. Kept as the single entry point for callers with no
  /// actor boundary to preserve between "fetch" and "classify" (e.g. tests).
  /// `ClipboardMonitor.checkNow()` calls the two halves separately instead —
  /// see their doc comments.
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
    guard let raw = pullRawPayload(from: pasteboard) else { return nil }
    return classify(raw)
  }

  /// T-PERF1: the main-isolated half of `read(from:)` — every real
  /// `PasteboardReading` call (`availableTypes`/`string(forType:)`/
  /// `data(forType:)`) happens here, and only here. Fetches ONLY the one
  /// representation the type-priority order actually resolves to, exactly
  /// like `read(from:)` always has — e.g. a Finder file copy that also
  /// carries a `.tiff` icon thumbnail never pays to fetch that thumbnail's
  /// bytes, since `.fileURL` already won. `ClipboardMonitor.checkNow()` calls
  /// this directly, still on `@MainActor` (per the "AppKit pasteboard access
  /// stays on the main actor" rule — real `NSPasteboard` reads must happen on
  /// the actor that owns the pasteboard session), then hands the `Sendable`
  /// result to `classify(_:)` off-main.
  public func pullRawPayload(from pasteboard: PasteboardReading) -> RawPayload? {
    let types = pasteboard.availableTypes

    if types.contains(.fileURL), let urlString = pasteboard.string(forType: .fileURL) {
      return .file(urlString: urlString)
    }

    if let imageData = firstAvailableImageData(from: pasteboard, types: types) {
      return .image(imageData)
    }

    if types.contains(.rtf), let rtfData = pasteboard.data(forType: .rtf) {
      return .richText(rtf: rtfData, fallbackPlainText: pasteboard.string(forType: .string))
    }

    if types.contains(.string), let text = pasteboard.string(forType: .string) {
      return .plainText(text)
    }

    return nil
  }

  /// T-PERF1: the CPU-only half of `read(from:)` — `ItemKind` decision,
  /// `previewText` construction (including the image-dimensions read), and
  /// the SHA-256 `contentHash` — touches no `PasteboardReading`, only the
  /// `Sendable` bytes `pullRawPayload(from:)` already fetched, so it's safe
  /// to run off `@MainActor`. `ClipboardMonitor.checkNow()` wraps this call
  /// in a `Task.detached(priority: .utility)`, the same pattern its blob
  /// write already uses (measured tens of ms for a large image — SHA-256
  /// over the full payload plus dimension decoding — worth moving off the
  /// main actor per this task's directive).
  public func classify(_ raw: RawPayload) -> Classification {
    switch raw {
    case .file(let urlString):
      return readFile(urlString)
    case .image(let data):
      return readImage(data)
    case .richText(let rtf, let fallbackPlainText):
      return readRichText(rtf, fallbackPlainText: fallbackPlainText)
    case .plainText(let text):
      return readPlainText(text)
    }
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
    if let dimensions = imagePixelDimensions(for: data) {
      return "Image, \(dimensions.width)\u{00D7}\(dimensions.height)"
    }
    return "Image (\(formattedByteCount(data.count)))"
  }

  /// T-PERF1: reads pixel dimensions via `ImageIO`'s
  /// `CGImageSourceCopyPropertiesAtIndex` instead of the previous
  /// `NSBitmapImageRep(data:)` — this now runs inside `classify(_:)`, off
  /// `@MainActor` (see hazard note in the task spec: `NSImage`/its AppKit
  /// siblings aren't documented thread-safe for every operation; `ImageIO`'s
  /// plain C API is). Reading just the properties dictionary (a small header
  /// parse) instead of decoding full pixel data is also strictly cheaper —
  /// exactly the kind of per-copy CPU work this task exists to get off the
  /// main actor for large images.
  private func imagePixelDimensions(for data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      return nil
    }
    return (width, height)
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
    fallbackPlainText: String?
  ) -> Classification {
    let previewText = plainTextPreview(forRTF: rtfData, fallbackPlainText: fallbackPlainText)
    return Classification(
      kind: .richText,
      previewText: previewText,
      contentHash: BlobStore.contentHash(of: rtfData),
      byteSize: rtfData.count,
      rawData: rtfData
    )
  }

  private func plainTextPreview(forRTF rtfData: Data, fallbackPlainText: String?)
    -> String
  {
    if let plainString = fallbackPlainText {
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
