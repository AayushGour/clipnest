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
