import Foundation
import Testing

@testable import ClipnestLinuxAppKit
@testable import ClipnestPlatformLinux

// GTKClipboardWriting itself needs a live GDK display (see that type's
// own "manual-verify only" doc comment) — nothing here touches GTK/GDK.
// These are the PURE pieces of P8-A's clipboard-write path: the MIME-type
// choice for image bytes, and the two file-clipboard payload formats
// (covered separately in `FileClipboardPayloadTests.swift`). Runtime proof
// that `GTKClipboardWriting` actually publishes these correctly through a
// real `GdkClipboard` lives in this task's decision log / PR description,
// not here — see coding-standards.md's testing rules ("never synthesize
// real key events or touch NSPasteboard from a test") applied to this
// platform's equivalent (never touch a real GDK clipboard from a test).
@Suite("GTKClipboardWriting.imageMimeType")
struct GTKClipboardWritingImageMimeTypeTests {
  @Test("Defaults to image/png — LinuxClipboardConstants.imageMimePriority's own top entry")
  func defaultsToPNG() {
    #expect(GTKClipboardWriting.imageMimeType(for: .png) == "image/png")
    #expect(
      GTKClipboardWriting.imageMimeType(for: .png) == LinuxClipboardConstants.imageMimePriority[0])
  }

  @Test("An explicit .tiff type is labeled image/tiff, never mislabeled as PNG")
  func tiffIsLabeledCorrectly() {
    #expect(GTKClipboardWriting.imageMimeType(for: .tiff) == "image/tiff")
  }

  @Test("Any other/unexpected ClipMediaType still falls back to image/png rather than crashing")
  func unexpectedTypeFallsBackToPNG() {
    #expect(GTKClipboardWriting.imageMimeType(for: .string) == "image/png")
  }
}

@Suite("GTKClipboardWriting rich text / plain text MIME constants")
struct GTKClipboardWritingMimeConstantsTests {
  @Test("Rich text publishes under richTextMimePriority's own top entry (text/html)")
  func richTextMimeMatchesReadPriority() {
    #expect(GTKClipboardWriting.richTextMimeType == "text/html")
    #expect(GTKClipboardWriting.richTextMimeType == LinuxClipboardConstants.richTextMimePriority[0])
  }

  @Test("Plain text fallback publishes under textMimePriority's own top entry")
  func plainTextMimeMatchesReadPriority() {
    #expect(GTKClipboardWriting.plainTextMimeType == "text/plain;charset=utf-8")
    #expect(GTKClipboardWriting.plainTextMimeType == LinuxClipboardConstants.textMimePriority[0])
  }
}

// The fidelity fix: `writeRichText` must offer a paste target EVERY
// representation Clipnest actually holds, not just a single relabeled
// one — see `LinuxPasteboard.data(forType: .rtf)`'s doc comment for the
// capture-side half of this fix. `representationsToPublish` is the pure
// decode-and-decide logic; the actual `gdk_content_provider_*` calls
// remain manual-verify only (see this file's top doc comment).
@Suite("GTKClipboardWriting.representationsToPublish")
struct GTKClipboardWritingRepresentationsToPublishTests {
  @Test(
    "Republishes every representation a LinuxRichTextBundle contains, under its own real MIME type")
  func republishesEveryBundledRepresentation() {
    let bundle = LinuxRichTextBundle(representations: [
      .init(mimeType: "text/html", data: Data("<b>hi</b>".utf8)),
      .init(mimeType: "text/rtf", data: Data("{\\rtf1 hi}".utf8)),
    ])
    let result = GTKClipboardWriting.representationsToPublish(for: bundle.encode())
    #expect(result == bundle.representations)
  }

  @Test(
    "Falls back to treating unwrapped bytes as flat text/html — legacy pre-fix blobs paste exactly as before"
  )
  func fallsBackToFlatHTMLForLegacyBlob() {
    let legacyBlob = Data("<html><body>legacy</body></html>".utf8)
    let result = GTKClipboardWriting.representationsToPublish(for: legacyBlob)
    #expect(result == [.init(mimeType: "text/html", data: legacyBlob)])
  }

  @Test("Falls back to flat text/html for an empty (zero-representation) bundle too")
  func fallsBackToFlatHTMLForEmptyBundle() {
    let emptyBundleBytes = LinuxRichTextBundle(representations: []).encode()
    let result = GTKClipboardWriting.representationsToPublish(for: emptyBundleBytes)
    #expect(result == [.init(mimeType: "text/html", data: emptyBundleBytes)])
  }

  @Test(
    "A single-representation bundle tagged as text/rtf (no text/html present) is preserved, not relabeled"
  )
  func singleRTFOnlyRepresentationIsNotRelabeled() {
    let bundle = LinuxRichTextBundle(representations: [
      .init(mimeType: "text/rtf", data: Data("{\\rtf1 hi}".utf8))
    ])
    let result = GTKClipboardWriting.representationsToPublish(for: bundle.encode())
    #expect(result == [.init(mimeType: "text/rtf", data: Data("{\\rtf1 hi}".utf8))])
  }
}
