import Foundation
import Testing

@testable import ClipnestCore
@testable import ClipnestPlatformLinux

@Suite("LinuxEditableRichText")
struct LinuxEditableRichTextTests {
  private func bundle(_ representations: (String, String)...) -> Data {
    LinuxRichTextBundle(
      representations: representations.map {
        .init(mimeType: $0.0, data: Data($0.1.utf8))
      }
    ).encode()
  }

  @Test func nilBlobGivesPlainRunNotLossy() {
    let loaded = LinuxEditableRichText.load(blob: nil, plainText: "hello")
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "hello")], isLossy: false))
  }

  @Test func cleanHtmlBundleLoadsFormattingNotLossy() {
    let blob = bundle(("text/html", "<b>hi</b> there"), ("application/rtf", "{\\rtf1 hi}"))
    let loaded = LinuxEditableRichText.load(blob: blob, plainText: "hi there")
    #expect(loaded.runs == [StyledRun(text: "hi", bold: true), StyledRun(text: " there")])
    #expect(!loaded.isLossy)
  }

  @Test func bundleWithTableIsLossy() {
    let blob = bundle(("text/html", "<table><tr><td>cell</td></tr></table>"))
    let loaded = LinuxEditableRichText.load(blob: blob, plainText: "cell")
    #expect(loaded.isLossy)
    #expect(loaded.runs.map(\.text).joined() == "cell")
  }

  @Test func rtfOnlyBundleFallsBackToPlainAndIsLossy() {
    let blob = bundle(("application/rtf", "{\\rtf1 hi}"))
    let loaded = LinuxEditableRichText.load(blob: blob, plainText: "hi")
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "hi")], isLossy: true))
  }

  @Test func legacyFlatHtmlBlobIsReadAndSavedBackAsBundle() throws {
    let legacy = Data("<i>old</i>".utf8)
    let loaded = LinuxEditableRichText.load(blob: legacy, plainText: "old")
    #expect(loaded.runs == [StyledRun(text: "old", italic: true)])
    #expect(!loaded.isLossy)
    let saved = try #require(
      LinuxRichTextBundle.decode(LinuxEditableRichText.blob(from: loaded.runs)))
    #expect(saved.representations.count == 1)
    #expect(saved.representations[0].mimeType == "text/html")
  }

  @Test func garbageBytesFallBackToPlainAndLossy() {
    let garbage = Data([0xFF, 0xFE, 0x00, 0x80, 0xC3])
    let loaded = LinuxEditableRichText.load(blob: garbage, plainText: "fallback")
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "fallback")], isLossy: true))
    var corrupt = Data("CNR1".utf8)
    corrupt.append(contentsOf: [9, 0, 0, 0, 1])
    #expect(LinuxEditableRichText.load(blob: corrupt, plainText: "p").isLossy)
  }

  @Test func savedBundleContainsOnlyRegeneratedHtml() throws {
    let blob = bundle(("text/html", "<b>x</b>"), ("application/rtf", "{\\rtf1 stale}"))
    let loaded = LinuxEditableRichText.load(blob: blob, plainText: "x")
    let saved = try #require(
      LinuxRichTextBundle.decode(LinuxEditableRichText.blob(from: loaded.runs)))
    #expect(saved.representations.map(\.mimeType) == ["text/html"])
    let html = String(decoding: saved.representations[0].data, as: UTF8.self)
    #expect(html.contains("<b>x</b>"))
    #expect(!html.contains("rtf"))
  }

  @Test func oversizedOrDeepHtmlFallsBackToPlainAndLossy() {
    let deep = String(repeating: "<b>", count: 10_000) + "x"
    let loaded = LinuxEditableRichText.load(blob: bundle(("text/html", deep)), plainText: "x")
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "x")], isLossy: true))
    let huge = Data(repeating: 0x61, count: 2_000_000)
    #expect(LinuxEditableRichText.load(blob: huge, plainText: "p").isLossy)
  }

  @Test func hugeDeclaredRepresentationCountDoesNotAllocateOrTrap() {
    let blob = Data("CNR1".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF])
    #expect(LinuxRichTextBundle.decode(blob) == nil)
    let loaded = LinuxEditableRichText.load(blob: blob, plainText: "p")
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "p")], isLossy: true))
  }

  @Test func htmlWithNoTextFallsBackToPlain() {
    let loaded = LinuxEditableRichText.load(
      blob: bundle(("text/html", "<html><body></body></html>")), plainText: "shown")
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "shown")], isLossy: true))
  }

  @Test func missingRichContentIsLossyEvenWithNoBlob() {
    let loaded = LinuxEditableRichText.load(blob: nil, plainText: "p", richContentMissing: true)
    #expect(loaded == EditableRichText(runs: [StyledRun(text: "p")], isLossy: true))
    let plainItem = LinuxEditableRichText.load(blob: nil, plainText: "p", richContentMissing: false)
    #expect(!plainItem.isLossy)
  }
}
