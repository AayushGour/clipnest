import Foundation
import Testing

@testable import ClipnestCore

/// A fake pasteboard used to drive `PasteboardReader` without touching the real
/// system pasteboard, per coding-standards.md ("never touch `NSPasteboard` from
/// a test").
///
/// P2-A (Linux port): spelled in terms of `ClipMediaType` (not
/// `NSPasteboard.PasteboardType` directly) — the exact same type on macOS
/// (`ClipMediaType` is a plain `typealias` there, see `ClipMediaType.swift`),
/// so this is a zero-behavior-change rename that also drops this file's need
/// for `import AppKit` entirely, letting the whole suite run on Linux too.
private struct FakePasteboard: PasteboardReading {
  var availableTypes: [ClipMediaType]
  var strings: [ClipMediaType: String] = [:]
  var datas: [ClipMediaType: Data] = [:]

  func string(forType type: ClipMediaType) -> String? {
    strings[type]
  }

  func data(forType type: ClipMediaType) -> Data? {
    datas[type]
  }
}

@Suite("PasteboardReader")
struct PasteboardReaderTests {

  @Test("Classifies plain text as .text")
  func classifiesPlainText() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "hello world"]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .text)
    #expect(result?.previewText == "hello world")
    #expect(result?.byteSize == Data("hello world".utf8).count)
  }

  @Test("Classifies a URL string as .link")
  func classifiesLink() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "https://example.com/path"]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .link)
    #expect(result?.previewText == "https://example.com/path")
  }

  @Test("Classifies RTF data as .richText")
  func classifiesRichText() {
    let rtfData = Data("{\\rtf1 hello}".utf8)
    let pasteboard = FakePasteboard(
      availableTypes: [.rtf, .string],
      strings: [.string: "hello"],
      datas: [.rtf: rtfData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .richText)
    #expect(result?.previewText == "hello")
    #expect(result?.byteSize == rtfData.count)
  }

  @Test("Rich text classification carries the RTF bytes as rawData for BlobStore")
  func richTextStoresRawRTFData() {
    let rtfData = Data("{\\rtf1\\ansi bold}".utf8)
    let pasteboard = FakePasteboard(
      availableTypes: [.rtf, .string],
      strings: [.string: "bold"],
      datas: [.rtf: rtfData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .richText)
    #expect(result?.rawData == rtfData)
    #expect(result?.previewText == "bold")
  }

  @Test("Same plain-text content hashes identically across calls")
  func hashIsStableForIdenticalContent() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "repeat me"]
    )

    let first = PasteboardReader().read(from: pasteboard)
    let second = PasteboardReader().read(from: pasteboard)

    #expect(first?.contentHash != nil)
    #expect(first?.contentHash == second?.contentHash)
  }

  @Test("Different plain-text content hashes differently")
  func hashDiffersForDifferentContent() {
    let pasteboardA = FakePasteboard(availableTypes: [.string], strings: [.string: "content A"])
    let pasteboardB = FakePasteboard(availableTypes: [.string], strings: [.string: "content B"])

    let resultA = PasteboardReader().read(from: pasteboardA)
    let resultB = PasteboardReader().read(from: pasteboardB)

    #expect(resultA?.contentHash != resultB?.contentHash)
  }

  @Test("Returns nil for pasteboard content with no supported types")
  func returnsNilForUnsupportedContent() {
    let pasteboard = FakePasteboard(availableTypes: [.tiff])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result == nil)
  }

  @Test("A non-URL plain string is not misclassified as a link")
  func doesNotMisclassifyPlainTextAsLink() {
    let pasteboard = FakePasteboard(
      availableTypes: [.string],
      strings: [.string: "Hello: this has a colon, not a URL"]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .text)
  }

  // MARK: - Image (T20)

  @Test(
    "Classifies image bytes as .image, with dimensions in previewText and rawData for BlobStore")
  func classifiesImage() {
    let imageData = ImageFixtures.makeTinyImageData(width: 2, height: 3)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.byteSize == imageData.count)
    #expect(result?.rawData == imageData)
    #expect(result?.previewText.contains("2") == true)
    #expect(result?.previewText.contains("3") == true)
    #expect(result?.fileURL == nil)
  }

  @Test("Image content hashing is stable across calls, for BlobStore dedup")
  func imageHashIsStableForIdenticalBytes() {
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4, format: .tiff)
    let pasteboard = FakePasteboard(availableTypes: [.tiff], datas: [.tiff: imageData])

    let first = PasteboardReader().read(from: pasteboard)
    let second = PasteboardReader().read(from: pasteboard)

    #expect(first?.contentHash != nil)
    #expect(first?.contentHash == second?.contentHash)
  }

  @Test("An image is classified as .image even when a .string representation is also present")
  func imagePrioritizedOverPlainTextRepresentation() {
    let imageData = ImageFixtures.makeTinyImageData(width: 2, height: 2)
    let pasteboard = FakePasteboard(
      availableTypes: [.png, .string],
      strings: [.string: "https://example.com/image.png"],
      datas: [.png: imageData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
  }

  // MARK: - T-PF2: PNG-preferred image capture + capture-time ceilings

  @Test("PNG is preferred over TIFF when both representations are offered")
  func prefersPNGOverTIFFWhenBothOffered() {
    let pngData = ImageFixtures.makeTinyImageData(width: 2, height: 2, format: .png)
    let tiffData = ImageFixtures.makeTinyImageData(width: 5, height: 5, format: .tiff)
    let pasteboard = FakePasteboard(
      availableTypes: [.tiff, .png],
      datas: [.tiff: tiffData, .png: pngData]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.rawData == pngData)
    #expect(result?.byteSize == pngData.count)
    // T-PF2 finding (now superseded by T-PF5b, see below): whenever both
    // representations are offered, `rawData`/`byteSize` are derived from
    // the PNG bytes, never the TIFF bytes. This part of the test is
    // platform-agnostic (rawData/byteSize selection, not hashing) and runs
    // on every platform.
    #if os(macOS)
      // P2-A (Linux port): only this half is gated — it exercises
      // `PasteboardReader`'s DEFAULT (real, uninjected) pixel hasher, which
      // is the Apple-only `CoreGraphicsImagePixelHasher` on macOS but the
      // always-nil `UnavailableImagePixelHasher` off it (see
      // `PlatformDefaults.imagePixelHasher`) — off macOS `contentHash` would
      // fall back to the raw-byte hash, which is exactly what the assertions
      // below prove it must NOT equal here. `PasteboardReaderPixelHashTests`
      // below already covers this seam's portable contract via an injected
      // fake, on every platform.
      //
      // T-PF5b: `contentHash` itself is no longer a raw-byte hash for
      // `.image` — it's `PasteboardReader`'s default (real, uninjected)
      // `CoreGraphicsImagePixelHasher`'s format-independent PIXEL-content
      // hash of `pngData`. This is exactly what fixes the T-PF2-era
      // "container changes the digest" problem the old version of this
      // comment described: the SAME picture now hashes identically whether
      // it's captured as PNG or TIFF (proven directly, chunk-size and
      // container-independence both, by `CoreGraphicsImagePixelHasherTests`)
      // — this test only additionally confirms `PasteboardReader`'s default
      // init wires that real hasher in, not a stub.
      let expectedHash = CoreGraphicsImagePixelHasher().pixelContentHash(of: pngData)
      #expect(result?.contentHash == expectedHash)
      #expect(result?.contentHash != BlobStore.contentHash(of: pngData))
      #expect(result?.contentHash != BlobStore.contentHash(of: tiffData))
    #endif
  }

  @Test("TIFF is used when it's the only image representation offered")
  func usesTIFFWhenOnlyTIFFOffered() {
    let tiffData = ImageFixtures.makeTinyImageData(width: 4, height: 4, format: .tiff)
    let pasteboard = FakePasteboard(availableTypes: [.tiff], datas: [.tiff: tiffData])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.rawData == tiffData)
    #expect(result?.byteSize == tiffData.count)
  }

  @Test("An image exactly at the byte-size ceiling is still captured (boundary is inclusive)")
  func acceptsImageAtByteSizeCeiling() {
    // Zero-filled, undecodable-as-a-real-image bytes at exactly the
    // ceiling — mirrors `ClipboardMonitorTests`'s T-PERF3 fixture shape
    // (byte-count cost, not decode cost, is what's under test here).
    let atCeiling = Data(count: PasteboardReader.maxCapturedImageByteSize)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: atCeiling])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.byteSize == atCeiling.count)
  }

  @Test("An image over the byte-size ceiling is rejected cleanly — read(from:) returns nil")
  func rejectsImageOverByteSizeCeiling() {
    let oversized = Data(count: PasteboardReader.maxCapturedImageByteSize + 1)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: oversized])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result == nil)
  }

  @Test(
    "An image over the pixel-dimension ceiling is rejected cleanly — read(from:) returns nil")
  func rejectsImageOverPixelDimensionCeiling() {
    let oversizedWidth = Int(PasteboardReader.maxCapturedImagePixelDimension) + 1
    // A single-row image keeps this fixture cheap to construct/encode while
    // still genuinely exceeding the ceiling on its width axis.
    let imageData = ImageFixtures.makeTinyImageData(width: oversizedWidth, height: 1)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result == nil)
  }

  @Test("A well-formed image under both ceilings is unaffected — captured exactly as before")
  func underCeilingImageIsUnaffected() {
    let imageData = ImageFixtures.makeTinyImageData(width: 10, height: 12, format: .png)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.rawData == imageData)
    #expect(result?.byteSize == imageData.count)
    #expect(result?.previewText.contains("10") == true)
    #expect(result?.previewText.contains("12") == true)
  }

  // MARK: - File (T20)

  @Test(
    "Classifies a file reference (.fileURL) as .file with the filename as previewText, without reading the file (byteSize 0)"
  )
  func classifiesFile() throws {
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clip-\(UUID().uuidString).txt")
    let fileContents = Data("file contents".utf8)
    try fileContents.write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let pasteboard = FakePasteboard(
      availableTypes: [.fileURL],
      strings: [.fileURL: tempFile.absoluteString]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .file)
    #expect(result?.previewText == tempFile.lastPathComponent)
    // Size is NOT read at capture (see `PasteboardReader.readFile`) — the
    // synchronous `attributesOfItem` on the main-actor capture path froze the
    // app on iCloud/TCC-gated files. `byteSize` is 0 regardless of the real
    // file (which exists here); it's read off-main only when a preview needs it.
    #expect(result?.byteSize == 0)
    #expect(result?.fileURL == tempFile)
    #expect(result?.rawData == nil)
  }

  @Test("A file reference is classified as .file even when an image thumbnail type is also present")
  func filePrioritizedOverImageThumbnail() throws {
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clip-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }
    let thumbnail = ImageFixtures.makeTinyImageData(width: 1, height: 1, format: .tiff)

    let pasteboard = FakePasteboard(
      availableTypes: [.fileURL, .tiff],
      strings: [.fileURL: tempFile.absoluteString],
      datas: [.tiff: thumbnail]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .file)
  }

  @Test("A file reference to a nonexistent path still classifies, with byteSize 0")
  func fileReferenceToMissingPathFallsBackToZeroByteSize() {
    let missingFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "does-not-exist-\(UUID().uuidString).txt")
    let pasteboard = FakePasteboard(
      availableTypes: [.fileURL],
      strings: [.fileURL: missingFile.absoluteString]
    )

    let result = PasteboardReader().read(from: pasteboard)

    #expect(result?.kind == .file)
    #expect(result?.byteSize == 0)
  }

  // MARK: - T-PERF1: pullRawPayload/classify split (off-main classification)

  @Test("pullRawPayload + classify together produce the exact same Classification as read(from:)")
  func pullRawPayloadPlusClassifyMatchesRead() {
    let imageData = ImageFixtures.makeTinyImageData(width: 5, height: 7)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])
    let reader = PasteboardReader()

    let viaRead = reader.read(from: pasteboard)
    let raw = reader.pullRawPayload(from: pasteboard)
    // T-PF2: `classify` is itself now `(RawPayload) -> Classification?`, so
    // `flatMap` (not `map`) keeps `viaSplit` a single-level `Classification?`
    // instead of double-wrapping it.
    let viaSplit = raw.flatMap(reader.classify)

    #expect(viaSplit?.kind == viaRead?.kind)
    #expect(viaSplit?.previewText == viaRead?.previewText)
    #expect(viaSplit?.contentHash == viaRead?.contentHash)
    #expect(viaSplit?.byteSize == viaRead?.byteSize)
    #expect(viaSplit?.rawData == viaRead?.rawData)
  }

  /// T-PERF1's whole point: `classify(_:)` must be safe to run off
  /// `@MainActor` — `ClipboardMonitor.checkNow()` wraps it in a
  /// `Task.detached`. This is a genuine structural + runtime proof, not a
  /// fragile timing assertion: `classify` takes only the `Sendable`
  /// `RawPayload` (no `PasteboardReading`), so Swift 6's strict concurrency
  /// checker already requires no `await`/actor context to call it from
  /// inside `Task.detached` below (a `classify` that secretly needed
  /// `@MainActor` simply would not compile here) — and the runtime
  /// `Thread.isMainThread` check confirms it's genuinely NOT running on the
  /// main thread either, not just compiling as if it could be.
  @Test("classify(_:) genuinely runs off the main thread when called from Task.detached")
  @MainActor
  func classifyRunsOffTheMainThread() async {
    // `Thread.isMainThread` itself is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` (it
    // wants callers to prefer actor checks instead) — wrapped in a plain
    // synchronous helper so it can still be read from inside the async
    // closures below; the helper itself does nothing actor-related, so this
    // doesn't weaken the check.
    let reader = PasteboardReader()
    let raw = PasteboardReader.RawPayload.plainText("off-main classify check")

    // The STRUCTURAL half of the proof runs on every platform: `classify`
    // takes only the `Sendable` `RawPayload`, so Swift 6 strict concurrency
    // already rejects a `classify` that secretly needed `@MainActor` — this
    // call would not compile inside `Task.detached` if it did.
    let wasMainThread = await Task.detached(priority: .utility) { () -> Bool in
      _ = reader.classify(raw)
      return isCurrentlyOnMainThread()
    }.value

    // The RUNTIME half is macOS-only, and deliberately so. On Darwin
    // `@MainActor` is bound to the OS main thread, so `Thread.isMainThread`
    // is a meaningful witness. On Linux it is not: swift-corelibs reports the
    // real OS thread, while the MainActor executor runs this `@MainActor`
    // test body on a cooperative-pool thread. There, BOTH the sanity check
    // below and `!wasMainThread` would be measuring nothing — `!wasMainThread`
    // would pass vacuously, which is worse than not asserting it, so it is
    // gated rather than left to look like coverage it does not provide.
    #if os(macOS)
      #expect(isCurrentlyOnMainThread())  // sanity: this test starts on the main thread
      #expect(!wasMainThread)
    #endif
  }
}

/// See `classifyRunsOffTheMainThread`'s doc comment for why this exists
/// instead of referencing `Thread.isMainThread` directly.
private func isCurrentlyOnMainThread() -> Bool {
  Thread.isMainThread
}

// MARK: - T-PF5b/T-PF5e: injected pixel hash + megapixel memory ceiling

/// A fake `ImagePixelHashing` — proves `PasteboardReader` wires the
/// injected hasher into `.image` classification (`stubbedHash`), and lets
/// the T-PF5e memory-safety tests below assert the hasher is never even
/// CALLED for an over-`maxPixelHashPixelCount` image (`callCount`). A
/// plain `final class` guarded by a lock, not the `actor` shape
/// `OCRBackfillCoordinatorTests`'s `FakeBackfillRecognizer` uses, because
/// `ImagePixelHashing.pixelContentHash(of:)` is a SYNCHRONOUS protocol
/// requirement — an actor could only satisfy that `nonisolated`, which
/// can't touch actor-isolated state — so this stays genuinely `Sendable`
/// under Swift 6 strict concurrency via `NSLock` instead, while remaining
/// callable synchronously from `PasteboardReader.classify(_:)`.
private final class FakeImagePixelHashing: ImagePixelHashing, @unchecked Sendable {
  private let lock = NSLock()
  private var callCountStorage = 0
  private let stubbedHash: String?

  init(stubbedHash: String?) {
    self.stubbedHash = stubbedHash
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCountStorage
  }

  func pixelContentHash(of imageData: Data) -> String? {
    lock.lock()
    callCountStorage += 1
    lock.unlock()
    return stubbedHash
  }
}

@Suite("PasteboardReader pixel hash + memory ceiling")
struct PasteboardReaderPixelHashTests {

  @Test("Image contentHash uses the injected pixel hasher, not the raw-byte hash")
  func imageContentHashUsesInjectedPixelHasher() {
    let imageData = ImageFixtures.makeTinyImageData(width: 10, height: 10)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])
    let hasher = FakeImagePixelHashing(stubbedHash: "sentinel-pixel-hash")
    let reader = PasteboardReader(pixelHasher: hasher)

    let result = reader.read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.contentHash == "sentinel-pixel-hash")
    #expect(result?.contentHash != BlobStore.contentHash(of: imageData))
    #expect(hasher.callCount == 1)
  }

  @Test("Falls back to the raw-byte hash when the pixel hasher returns nil (undecodable)")
  func imageContentHashFallsBackWhenHasherReturnsNil() {
    let imageData = ImageFixtures.makeTinyImageData(width: 10, height: 10)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])
    let hasher = FakeImagePixelHashing(stubbedHash: nil)
    let reader = PasteboardReader(pixelHasher: hasher)

    let result = reader.read(from: pasteboard)

    #expect(result?.contentHash == BlobStore.contentHash(of: imageData))
    #expect(hasher.callCount == 1)
  }

  @Test(
    "T-PF5e: an image over the total-pixel-count ceiling falls back to the raw-byte hash WITHOUT ever calling the pixel hasher — the memory-safety proof"
  )
  func imageContentHashFallsBackAboveMegapixelCeilingWithoutCallingHasher() {
    // 20,000 x 2,001 = 40,020,000 px — over `maxPixelHashPixelCount`
    // (40,000,000) while each axis individually stays at/under
    // `maxCapturedImagePixelDimension` (20,000), so this exercises the
    // NEW total-pixel-count ceiling specifically, not the existing
    // per-axis one. A PNG of this mostly-uninitialized pixel data
    // compresses to well under `maxCapturedImageByteSize` (measured
    // ~700 KB in this task's handoff), so it also passes that ceiling —
    // exactly the "small file, huge decoded grid" shape T-PF5e exists to
    // guard against.
    let width = 20_000
    let height = 2_001
    #expect(width * height > PasteboardReader.maxPixelHashPixelCount)
    #expect(CGFloat(width) <= PasteboardReader.maxCapturedImagePixelDimension)
    #expect(CGFloat(height) <= PasteboardReader.maxCapturedImagePixelDimension)

    let imageData = ImageFixtures.makeTinyImageData(width: width, height: height)
    #expect(imageData.count <= PasteboardReader.maxCapturedImageByteSize)

    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])
    let hasher = FakeImagePixelHashing(stubbedHash: "sentinel-pixel-hash")
    let reader = PasteboardReader(pixelHasher: hasher)

    let result = reader.read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.contentHash == BlobStore.contentHash(of: imageData))
    #expect(result?.contentHash != "sentinel-pixel-hash")
    #expect(hasher.callCount == 0)
  }

  @Test("An image just under the total-pixel-count ceiling still uses the pixel hash")
  func imageContentHashUsesPixelHashJustUnderMegapixelCeiling() {
    // 20,000 x 1,999 = 39,980,000 px — just under `maxPixelHashPixelCount`
    // (40,000,000).
    let width = 20_000
    let height = 1_999
    #expect(width * height < PasteboardReader.maxPixelHashPixelCount)

    let imageData = ImageFixtures.makeTinyImageData(width: width, height: height)
    #expect(imageData.count <= PasteboardReader.maxCapturedImageByteSize)

    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])
    let hasher = FakeImagePixelHashing(stubbedHash: "sentinel-pixel-hash")
    let reader = PasteboardReader(pixelHasher: hasher)

    let result = reader.read(from: pasteboard)

    #expect(result?.contentHash == "sentinel-pixel-hash")
    #expect(hasher.callCount == 1)
  }

  @Test("The pixel hasher is never reached for an image rejected by the byte-size ceiling")
  func pixelHasherNotCalledForByteSizeRejectedImage() {
    let oversized = Data(count: PasteboardReader.maxCapturedImageByteSize + 1)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: oversized])
    let hasher = FakeImagePixelHashing(stubbedHash: "sentinel-pixel-hash")
    let reader = PasteboardReader(pixelHasher: hasher)

    let result = reader.read(from: pasteboard)

    #expect(result == nil)
    #expect(hasher.callCount == 0)
  }

  @Test("The pixel hasher is never reached for an image rejected by the pixel-dimension ceiling")
  func pixelHasherNotCalledForPixelDimensionRejectedImage() {
    let oversizedWidth = Int(PasteboardReader.maxCapturedImagePixelDimension) + 1
    // A single-row image keeps this fixture cheap to construct/encode
    // (mirrors `rejectsImageOverPixelDimensionCeiling`'s fixture shape).
    let imageData = ImageFixtures.makeTinyImageData(width: oversizedWidth, height: 1)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])
    let hasher = FakeImagePixelHashing(stubbedHash: "sentinel-pixel-hash")
    let reader = PasteboardReader(pixelHasher: hasher)

    let result = reader.read(from: pasteboard)

    #expect(result == nil)
    #expect(hasher.callCount == 0)
  }

  @Test(".text/.richText/.link/.file contentHash is unaffected by the injected pixel hasher")
  func nonImageKindsIgnorePixelHasher() {
    let hasher = FakeImagePixelHashing(stubbedHash: "sentinel-pixel-hash")
    let reader = PasteboardReader(pixelHasher: hasher)

    let textPasteboard = FakePasteboard(
      availableTypes: [.string], strings: [.string: "plain text"])
    let textResult = reader.read(from: textPasteboard)
    #expect(textResult?.kind == .text)
    #expect(textResult?.contentHash == BlobStore.contentHash(of: Data("plain text".utf8)))

    let linkPasteboard = FakePasteboard(
      availableTypes: [.string], strings: [.string: "https://example.com"])
    let linkResult = reader.read(from: linkPasteboard)
    #expect(linkResult?.kind == .link)
    #expect(linkResult?.contentHash == BlobStore.contentHash(of: Data("https://example.com".utf8)))

    let rtfData = Data("{\\rtf1 hello}".utf8)
    let richTextPasteboard = FakePasteboard(
      availableTypes: [.rtf, .string], strings: [.string: "hello"], datas: [.rtf: rtfData])
    let richTextResult = reader.read(from: richTextPasteboard)
    #expect(richTextResult?.kind == .richText)
    #expect(richTextResult?.contentHash == BlobStore.contentHash(of: rtfData))

    let urlString = "file:///tmp/does-not-need-to-exist.txt"
    let filePasteboard = FakePasteboard(
      availableTypes: [.fileURL], strings: [.fileURL: urlString])
    let fileResult = reader.read(from: filePasteboard)
    #expect(fileResult?.kind == .file)
    #expect(fileResult?.contentHash == BlobStore.contentHash(of: Data(urlString.utf8)))

    #expect(hasher.callCount == 0)
  }
}

// MARK: - P2-A (Linux port): injected ImageMetadataProbing/RichTextFlattening

/// A fake `ImageMetadataProbing` — proves `PasteboardReader` wires the
/// injected probe into image classification, and that a probe returning
/// `nil` falls back to the existing "undecodable" preview-text/hash
/// behavior unchanged.
private struct FakeImageMetadataProbing: ImageMetadataProbing {
  let stubbedDimensions: (width: Int, height: Int)?

  func pixelDimensions(of imageData: Data) -> (width: Int, height: Int)? {
    stubbedDimensions
  }
}

/// A fake `RichTextFlattening` — proves `PasteboardReader` wires the
/// injected flattener into rich-text classification, only when no
/// `fallbackPlainText` (`.string` representation) is available on the
/// pasteboard, matching `plainTextPreview`'s existing priority order.
private struct FakeRichTextFlattening: RichTextFlattening {
  let stubbedPlainText: String?

  func plainText(fromRTF data: Data) -> String? {
    stubbedPlainText
  }
}

@Suite("PasteboardReader injected ImageMetadataProbing/RichTextFlattening (P2-A)")
struct PasteboardReaderPlatformSeamTests {

  @Test("An injected ImageMetadataProbing drives the image previewText dimensions")
  func injectedImageMetadataProbeDrivesPreviewText() {
    let probe = FakeImageMetadataProbing(stubbedDimensions: (width: 999, height: 111))
    let reader = PasteboardReader(imageMetadataProbe: probe)
    // Bytes need not be a real image at all — the probe is a full stand-in
    // for dimension detection, exactly like `FakeImagePixelHashing` is a
    // full stand-in for hashing.
    let imageData = Data([0x00, 0x01, 0x02, 0x03])
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])

    let result = reader.read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.previewText == "Image, 999\u{00D7}111")
  }

  @Test("A nil-returning ImageMetadataProbing falls back to the byte-count previewText")
  func nilImageMetadataProbeFallsBackToByteCountPreview() {
    let probe = FakeImageMetadataProbing(stubbedDimensions: nil)
    let reader = PasteboardReader(imageMetadataProbe: probe)
    let imageData = Data(count: 42)
    let pasteboard = FakePasteboard(availableTypes: [.png], datas: [.png: imageData])

    let result = reader.read(from: pasteboard)

    #expect(result?.kind == .image)
    #expect(result?.previewText.contains("999") == false)
    #expect(result?.previewText.contains("Image") == true)
  }

  @Test(
    "An injected RichTextFlattening drives the rich-text previewText when no fallback string exists"
  )
  func injectedRichTextFlattenerDrivesPreviewTextWithNoFallback() {
    let flattener = FakeRichTextFlattening(stubbedPlainText: "  flattened content  ")
    let reader = PasteboardReader(richTextFlattener: flattener)
    let rtfData = Data("{\\rtf1 anything}".utf8)
    let pasteboard = FakePasteboard(availableTypes: [.rtf], datas: [.rtf: rtfData])

    let result = reader.read(from: pasteboard)

    #expect(result?.kind == .richText)
    #expect(result?.previewText == "flattened content")
  }

  @Test("The pasteboard's own .string fallback wins over RichTextFlattening, unchanged priority")
  func fallbackPlainTextStillWinsOverRichTextFlattener() {
    let flattener = FakeRichTextFlattening(stubbedPlainText: "should not be used")
    let reader = PasteboardReader(richTextFlattener: flattener)
    let rtfData = Data("{\\rtf1 anything}".utf8)
    let pasteboard = FakePasteboard(
      availableTypes: [.rtf, .string], strings: [.string: "the real fallback"],
      datas: [.rtf: rtfData])

    let result = reader.read(from: pasteboard)

    #expect(result?.previewText == "the real fallback")
  }

  @Test("A nil-returning RichTextFlattening falls back to the \"Rich Text\" placeholder")
  func nilRichTextFlattenerFallsBackToPlaceholder() {
    let flattener = FakeRichTextFlattening(stubbedPlainText: nil)
    let reader = PasteboardReader(richTextFlattener: flattener)
    let rtfData = Data("{\\rtf1 anything}".utf8)
    let pasteboard = FakePasteboard(availableTypes: [.rtf], datas: [.rtf: rtfData])

    let result = reader.read(from: pasteboard)

    #expect(result?.previewText == "Rich Text")
  }
}
