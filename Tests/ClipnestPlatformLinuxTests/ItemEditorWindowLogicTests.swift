// ItemEditorWindowLogicTests.swift
//
// T-EDIT9: the pure helpers behind the GTK item editor (tag naming and the
// run <-> buffer-span mapping). The window itself needs a display and is
// verified manually (Wayland/X11).
import ClipnestCore
import ClipnestViewModels
import Foundation
import Testing

@testable import ClipnestGTK

@Suite("ItemEditorWindowLogic")
struct ItemEditorWindowLogicTests {
  @Test func tagNamesForBoldItalicRunAreStableAndSorted() {
    let run = StyledRun(text: "x", bold: true, italic: true)
    #expect(ItemEditorTagNames.name(for: run) == ["b", "i"])
    let rich = StyledRun(
      text: "x", bold: true, underline: true, colorHex: "#FF0000", fontFamily: "Serif",
      fontSizePt: 12)
    let expected = ["b", "color:#ff0000", "family:Serif", "size:12.0", "u"]
    #expect(ItemEditorTagNames.name(for: rich) == expected)
    #expect(ItemEditorTagNames.name(for: rich) == ItemEditorTagNames.name(for: rich))
  }

  @Test func plainRunHasNoTags() {
    #expect(ItemEditorTagNames.name(for: StyledRun(text: "plain")).isEmpty)
  }

  @Test func bufferSpansMapBackToIdenticalRuns() {
    let runs = [
      StyledRun(text: "plain "),
      StyledRun(text: "bold", bold: true),
      StyledRun(text: " and ", italic: true, underline: true),
      StyledRun(
        text: "styled \u{1F600}", colorHex: "#00AA11", fontFamily: "DejaVu Sans", fontSizePt: 14.5),
    ]
    let (text, spans) = StyledRunMapping.flatten(runs)
    // Simulate the buffer: spans carry only tag names, the way the window
    // reads them back.
    let viaTags = spans.map { span in
      StyleSpan(
        start: span.start, length: span.length,
        run: ItemEditorTagNames.style(fromTagNames: ItemEditorTagNames.name(for: span.run)))
    }
    #expect(StyledRunMapping.runs(text: text, spans: viaTags) == runs)
  }

  @Test func tagNamesForSpansAreDeduplicated() {
    let bold = StyledRun(text: "", bold: true)
    let spans = [
      StyleSpan(start: 0, length: 1, run: bold), StyleSpan(start: 3, length: 2, run: bold),
    ]
    #expect(ItemEditorTagNames.tagNames(for: spans) == ["b"])
  }

  @Test func outputForContentKeepsTextAndReportsFormatting() {
    let runs = [StyledRun(text: "a "), StyledRun(text: "b", bold: true)]
    let blob = Data([1, 2, 3])
    let out = ItemEditorWindow.output(
      text: " a b\n", runs: runs, recognizedText: false, blobFromRuns: { _ in blob })
    #expect(out == EditorOutput(plainText: " a b\n", hasFormatting: true, richBlob: blob))
    let plain = ItemEditorWindow.output(
      text: "a", runs: [StyledRun(text: "a")], recognizedText: false, blobFromRuns: { _ in blob })
    #expect(plain.hasFormatting == false)
  }

  @Test func outputForRecognizedTextIsTrimmedPlainWithNoBlob() {
    let out = ItemEditorWindow.output(
      text: "  hi\n", runs: [StyledRun(text: "x", bold: true)], recognizedText: true,
      blobFromRuns: { _ in Data([9]) })
    #expect(out == EditorOutput(plainText: "hi", hasFormatting: false, richBlob: Data()))
  }

  @Test func tagsCarryRealStyleProperties() throws {
    let bold = try #require(GTKTextStyling.readBackStyle(forTagNamed: "b"))
    #expect(bold.weight == 700)
    let italic = try #require(GTKTextStyling.readBackStyle(forTagNamed: "i"))
    #expect(italic.style == 2)  // PANGO_STYLE_ITALIC
    let underline = try #require(GTKTextStyling.readBackStyle(forTagNamed: "u"))
    #expect(underline.underline == 1)  // PANGO_UNDERLINE_SINGLE
  }
}
