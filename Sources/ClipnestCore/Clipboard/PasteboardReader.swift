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

  /// Pasteboard types checked for image bytes, in priority order: `.png`
  /// first, `.tiff` only as a fallback when no `.png` representation is
  /// offered. Both are still checked (not just one) because different apps
  /// offer different image representations — e.g. macOS screenshots and
  /// Preview commonly offer both, some web/image apps offer `.png` only.
  ///
  /// T-PF2: `.tiff` used to be checked first. Two problems with that: (1) a
  /// stored TIFF blob is roughly 10x larger on disk than the equivalent PNG
  /// for typical screenshot/photo content — a real capture measured this at
  /// 25,273,086 uncompressed bytes (`.claude/logs/tester.md`); (2) when a
  /// source app offers `.png` only, asking `NSPasteboard` for `.tiff` forces
  /// it to synthesize a TIFF representation in-process, on THIS (main)
  /// actor, at request time — real conversion work masquerading as a cheap
  /// pasteboard read. Preferring `.png` avoids both: it's the smaller,
  /// already-compressed representation, and it's read directly rather than
  /// converted. `Paster.normalizedToTIFF` already decodes+re-encodes
  /// whichever format was actually stored back to `.tiff` at paste time (see
  /// its doc comment), so downstream paste behavior is unaffected by which
  /// format was captured.
  private static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

  /// Captured images whose byte size exceeds this are rejected — `classify`
  /// returns `nil` for them — before their bytes are ever hashed
  /// (`BlobStore.contentHash`) or hand off to `ClipboardMonitor` for
  /// `BlobStore` writing. A defensive ceiling against a pathologically large
  /// capture bloating on-disk storage and the SHA-256 cost paid on every
  /// future dedup check against it. 50 MB matches
  /// `VisionTextRecognizer.maxByteSize`'s established ceiling and its
  /// rationale ("comfortably covers any realistic screenshot or pasted
  /// photo") — comfortably above the 25,273,086-byte real-world capture that
  /// motivated this task, with margin for a legitimately large photo.
  ///
  /// T-PF6: deliberately kept as its OWN named constant, not unified with
  /// `VisionTextRecognizer.maxByteSize` into one shared value, even though
  /// today they're numerically equal. They answer two different questions —
  /// "how big a file are we willing to persist + hash for every future dedup
  /// check" here, vs. "how big a file are we willing to feed to a
  /// synchronous, queued Vision request" there — that happen to land on the
  /// same number today because both derive from the same "comfortably covers
  /// any realistic screenshot/photo" intuition, not because one is
  /// mechanically defined in terms of the other. A capture ceiling change
  /// (e.g. loosening it because disk is cheap) has no logical reason to also
  /// change the OCR ceiling (bounded by Vision request latency/memory), and
  /// vice versa. Collapsing two independently-motivated values into one
  /// shared constant would create FALSE coupling — a future change to one
  /// policy silently changing the other — which this codebase's DRY rule
  /// does not require: DRY targets duplicated LOGIC/facts, not coincidental
  /// equality between values that could legitimately diverge. If you're
  /// re-reviewing this: this was a deliberate call, not an oversight — see
  /// the identical note on `VisionTextRecognizer.maxByteSize`.
  public static let maxCapturedImageByteSize = 50_000_000

  /// Captured images whose pixel dimensions exceed this on either axis are
  /// rejected the same way `maxCapturedImageByteSize` is — guards against a
  /// decompression-bomb-shaped image (a small byte count that decodes to an
  /// enormous pixel grid), which the byte-size ceiling alone wouldn't catch
  /// since it's checked on the encoded bytes, not the decoded grid. Mirrors
  /// `VisionTextRecognizer.maxPixelDimension`'s identical rationale and
  /// value. Images that fail to decode at all (so their dimensions can't be
  /// determined) are NOT rejected by this check — see `readImage`'s doc
  /// comment.
  ///
  /// T-PF6: same deliberate non-unification call as
  /// `maxCapturedImageByteSize` above — this bounds "how large a
  /// decompression-bomb-shaped image are we willing to persist," a different
  /// policy question from `VisionTextRecognizer.maxPixelDimension`'s "how
  /// large an image are we willing to hand to Vision," even though both
  /// currently land on 20,000px. Not mechanically linked; see that note for
  /// the full reasoning.
  public static let maxCapturedImagePixelDimension: CGFloat = 20_000

  /// T-PF5e: total pixel count (`width × height`) above which the
  /// pixel-content hash path (`pixelHasher`) is skipped in favor of the
  /// raw-byte `BlobStore.contentHash(of:)` — a defensive ceiling against
  /// the multi-gigabyte peak-memory risk `CoreGraphicsImagePixelHasher`
  /// introduces, which neither ceiling above bounds.
  ///
  /// T-PF5a measured REAL peak memory (`getrusage`, see `.claude/logs/
  /// tester.md`) for `CoreGraphicsImagePixelHasher` and found it converges
  /// to ~2.0-2.1x the raw DECODED RGBA8 buffer size, NOT the ~12 MB
  /// row-band chunk budget `CoreGraphicsImagePixelHasher
  /// .targetChunkByteSize` streams through — CoreGraphics' own opaque
  /// internal decode cache, outside this codebase's control, is the real
  /// driver: 266 MB peak measured for a 7680×4320 (33.2 MP) image, 746 MB
  /// peak for 12000×8000 (96 MP).
  ///
  /// Neither existing ceiling catches this: `maxCapturedImageByteSize`
  /// bounds the COMPRESSED size, and PNG compresses flat/solid-colour
  /// content extremely well, so a small PNG can decode to a
  /// multi-gigabyte raster; `maxCapturedImagePixelDimension` bounds only a
  /// SINGLE axis, so a 20,000 x 20,000 image (400 MP, ~1.6 GB decoded)
  /// currently passes it — and an elongated image such as 20,000×2,001
  /// (~40 MP) passes it too while still being large enough to matter here,
  /// since it bounds one axis, not the total grid.
  ///
  /// Ceiling chosen: 40,000,000 px (40 MP). Arithmetic behind it, at the
  /// measured ~2.1x worst-case multiplier:
  ///   40,000,000 px × 4 bytes/px (canonical RGBA8 render target) =
  ///     160,000,000 bytes (~153 MiB) raw decoded buffer
  ///   160,000,000 bytes × 2.1 ≈ 336,000,000 bytes (~320 MiB) worst-case peak
  /// — comfortably inside a "few hundred MB, not a gigabyte" budget for a
  /// background clipboard manager. A Retina 6K screenshot (6016×3384 ≈
  /// 20.4 MP) sits at roughly half this ceiling, well inside it.
  ///
  /// Bounds TOTAL pixel count, independently of
  /// `maxCapturedImagePixelDimension`'s per-axis bound — that's what
  /// catches the elongated-image case above. Unlike the two ceilings
  /// above, exceeding this one does NOT reject the capture (`readImage`
  /// still returns a `Classification`) — it only skips pixel hashing for
  /// THIS item, falling back to the raw-byte hash (see `imageContentHash`).
  /// The byte hash is still exact, so there's no false-dedup risk, only a
  /// loss of format-independence for pathologically large images — the
  /// correct trade per this task's directive, since a false dedup (data
  /// loss) is strictly worse than an occasional duplicate row. The same
  /// fallback applies when `imagePixelDimensions` can't determine
  /// dimensions at all: with no known pixel count, the memory risk can't
  /// be bounded, so the safe default is the byte hash.
  public static let maxPixelHashPixelCount = 40_000_000

  /// T-PERF1: the bytes/strings `pullRawPayload(from:)` fetched for whichever
  /// single type-priority branch matched — one case per branch `read(from:)`
  /// used to resolve in a single pass. `classify(_:)` turns this into a
  /// `Classification?` doing pure CPU work only (no further `PasteboardReading`
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

  /// T-PF5b: produces the format-independent pixel-content hash used for
  /// `.image` classification only (see `imageContentHash`) — injected the
  /// same way `blobStore` is injected into `ClipboardMonitor`/
  /// `SwiftDataClipStore` (a defaulted init parameter to the production
  /// conformance), so tests can substitute a fake without ever exercising
  /// a real `CoreGraphicsImagePixelHasher` decode.
  private let pixelHasher: any ImagePixelHashing

  public init(pixelHasher: any ImagePixelHashing = CoreGraphicsImagePixelHasher()) {
    self.pixelHasher = pixelHasher
  }

  /// Reads and classifies the current contents of `pasteboard` in one call —
  /// equivalent to `pullRawPayload(from:)` immediately followed by
  /// `classify(_:)`. Kept as the single entry point for callers with no
  /// actor boundary to preserve between "fetch" and "classify" (e.g. tests).
  /// `ClipboardMonitor.checkNow()` calls the two halves separately instead —
  /// see their doc comments.
  ///
  /// Type-priority order is `.fileURL` → image (`.png`/`.tiff`) → `.rtf` →
  /// `.string`, most-specific first. This matters because a single pasteboard
  /// change commonly carries multiple representations at once — e.g. a
  /// Finder file copy often also carries a `.tiff` icon thumbnail and/or a
  /// plain-text path string, and a browser image copy often also carries a
  /// `.string` URL — so a generic type must never win over a more specific
  /// one that's also present.
  ///
  /// Returns `nil` when the pasteboard holds no content this reader
  /// currently understands, OR when it holds an image that exceeds
  /// `maxCapturedImageByteSize`/`maxCapturedImagePixelDimension` (T-PF2 — see
  /// `classify(_:)`'s doc comment).
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
  ///
  /// T-PF2: returns `nil` for a `.image` payload that fails
  /// `maxCapturedImageByteSize`/`maxCapturedImagePixelDimension` (see
  /// `readImage`) — the same "nothing this cycle" contract `read(from:)`
  /// already has for an unsupported pasteboard type, so an over-ceiling
  /// image degrades to "not captured," never a crash or a partial
  /// (unhashed/unwritten) store. Every other `RawPayload` case always
  /// succeeds, same as before.
  public func classify(_ raw: RawPayload) -> Classification? {
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

  /// T-PF2: enforces `maxCapturedImageByteSize`/`maxCapturedImagePixelDimension`
  /// before doing anything with `data` a caller would need to undo (hashing,
  /// handing `rawData` off for a `BlobStore` write) — returns `nil` on
  /// either ceiling being exceeded, same "unusable capture, nothing stored"
  /// contract as an unsupported pasteboard type. The byte-size check is
  /// first and cheap (no decode). The pixel-dimension check needs decoded
  /// dimensions, so it reuses `imagePixelDimensions(for:)` — computed once
  /// here and threaded into `imagePreviewText` below rather than decoded
  /// twice. An image that fails to decode at all (`dimensions == nil`) is
  /// NOT rejected by the pixel check — undecodable bytes aren't a
  /// decompression-bomb shape, and rejecting them would change the existing
  /// "unrecognized image still captures, with a byte-count preview" behavior
  /// (see `imagePreviewText`), which stays frozen. `dimensions` is also
  /// threaded into `imageContentHash` below (T-PF5b/T-PF5e) — reusing this
  /// same decode-free header read is what lets the megapixel ceiling in
  /// `maxPixelHashPixelCount`'s doc comment run before any pixel-hash
  /// decode, with zero extra `ImageIO` cost.
  private func readImage(_ data: Data) -> Classification? {
    guard data.count <= Self.maxCapturedImageByteSize else { return nil }

    let dimensions = imagePixelDimensions(for: data)
    if let dimensions,
      CGFloat(dimensions.width) > Self.maxCapturedImagePixelDimension
        || CGFloat(dimensions.height) > Self.maxCapturedImagePixelDimension
    {
      return nil
    }

    return Classification(
      kind: .image,
      previewText: imagePreviewText(for: data, dimensions: dimensions),
      contentHash: imageContentHash(for: data, dimensions: dimensions),
      byteSize: data.count,
      rawData: data
    )
  }

  /// T-PF5b/T-PF5e: `.image`-only content hash — every other `ItemKind`
  /// keeps the plain raw-byte `BlobStore.contentHash(of:)` (see
  /// `readPlainText`/`readRichText`/`readFile`, unchanged). Prefers the
  /// injected `pixelHasher`'s format-independent, decoded-pixel-content
  /// hash, falling back to the raw-byte hash when: `dimensions` is `nil`
  /// (undecodable-for-dimensions bytes — same "can't bound the memory
  /// risk" reasoning as the megapixel case), OR `dimensions`' total pixel
  /// count exceeds `maxPixelHashPixelCount` (T-PF5e — see its doc comment
  /// for the full rationale/arithmetic; checked BEFORE `pixelHasher` is
  /// ever called, so an over-ceiling image never pays for the decode),
  /// OR `pixelHasher.pixelContentHash(of:)` itself returns `nil` (it
  /// couldn't decode `data` as an image at all).
  private func imageContentHash(for data: Data, dimensions: (width: Int, height: Int)?) -> String {
    guard let dimensions, dimensions.width * dimensions.height <= Self.maxPixelHashPixelCount else {
      return BlobStore.contentHash(of: data)
    }
    return pixelHasher.pixelContentHash(of: data) ?? BlobStore.contentHash(of: data)
  }

  private func imagePreviewText(for data: Data, dimensions: (width: Int, height: Int)?) -> String {
    if let dimensions {
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
