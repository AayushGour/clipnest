// GTKPangoMarkupTests.swift
//
// P7-D (Linux port, GTK4 view layer). See GTKKeyEventMappingTests.swift's
// top doc comment for the `ClipnestPlatformLinuxTests` -> `ClipnestGTK`
// manifest-dependency note that applies to every `GTK*Tests.swift` file.
import Testing

@testable import ClipnestGTK

@Suite("PangoMarkup")
struct GTKPangoMarkupTests {
  @Test("escape() escapes all five XML metacharacters, & first")
  func escapesMetacharacters() {
    #expect(PangoMarkup.escape("a & b") == "a &amp; b")
    #expect(PangoMarkup.escape("<tag>") == "&lt;tag&gt;")
    #expect(PangoMarkup.escape("\"quoted\"") == "&quot;quoted&quot;")
    #expect(PangoMarkup.escape("it's") == "it&apos;s")
    #expect(PangoMarkup.escape("a<b&c") == "a&lt;b&amp;c")
  }

  @Test("escape() is a no-op on text with none of the five characters")
  func escapeNoOpOnPlainText() {
    #expect(PangoMarkup.escape("hello world") == "hello world")
  }

  @Test("markup(for:) on a single non-matching segment just escapes it")
  func markupForPlainSegment() {
    let segments = [SearchHighlightSegments.Segment(text: "a & b", isMatch: false)]
    #expect(PangoMarkup.markup(for: segments) == "a &amp; b")
  }

  @Test("markup(for:) wraps a matching segment in a highlight span, after escaping")
  func markupForMatchingSegmentIsWrapped() {
    let segments = [SearchHighlightSegments.Segment(text: "<b>", isMatch: true)]
    let markup = PangoMarkup.markup(for: segments)
    #expect(markup.hasPrefix("<span"))
    #expect(markup.contains("&lt;b&gt;"))
    #expect(markup.hasSuffix("</span>"))
  }

  @Test("markup(for:) concatenates mixed segments in order")
  func markupForMixedSegments() {
    let segments = [
      SearchHighlightSegments.Segment(text: "hello ", isMatch: false),
      SearchHighlightSegments.Segment(text: "world", isMatch: true),
    ]
    let markup = PangoMarkup.markup(for: segments)
    #expect(markup.hasPrefix("hello "))
    #expect(markup.hasSuffix("</span>"))
    #expect(markup.contains(">world<"))
  }
}
