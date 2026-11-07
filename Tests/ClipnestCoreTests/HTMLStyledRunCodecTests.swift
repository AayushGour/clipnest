import Foundation
import Testing

@testable import ClipnestCore

@Suite("HTMLStyledRunCodec")
struct HTMLStyledRunCodecTests {
  private func parse(_ html: String) -> ParsedStyledText { HTMLStyledRunCodec.parse(html: html) }
  private func text(_ parsed: ParsedStyledText) -> String { parsed.runs.map(\.text).joined() }

  @Test func parsesBoldItalicUnderlineAndNestedCombinations() {
    let parsed = parse("a<b>b<i>bi</i></b><u>u</u><strong>s</strong><em>e</em>")
    #expect(!parsed.hasUnsupportedContent)
    #expect(
      parsed.runs == [
        StyledRun(text: "a"),
        StyledRun(text: "b", bold: true),
        StyledRun(text: "bi", bold: true, italic: true),
        StyledRun(text: "u", underline: true),
        StyledRun(text: "s", bold: true),
        StyledRun(text: "e", italic: true),
      ])
  }

  @Test func parsesSpanColorFamilyAndPointSize() {
    let parsed = parse(
      "<span style=\"color: rgb(255, 0, 0); font-family: Helvetica; font-size: 14pt; "
        + "font-weight: bold; font-style: italic; text-decoration: underline\">x</span>"
        + "<font color=\"#0a0\" face=\"Arial\">y</font><span style=\"font-size: 16px\">z</span>")
    #expect(!parsed.hasUnsupportedContent)
    #expect(
      parsed.runs == [
        StyledRun(
          text: "x", bold: true, italic: true, underline: true, colorHex: "#FF0000",
          fontFamily: "Helvetica", fontSizePt: 14),
        StyledRun(text: "y", colorHex: "#00AA00", fontFamily: "Arial"),
        StyledRun(text: "z", fontSizePt: 12),
      ])
  }

  @Test func quotedFontFamilyListIsKeptWithoutWarning() {
    let parsed = parse("<span style='font-family: \"Segoe UI\", sans-serif'>x</span>")
    #expect(!parsed.hasUnsupportedContent)
    #expect(parsed.runs == [StyledRun(text: "x", fontFamily: "Segoe UI, sans-serif")])
  }

  @Test func translucentColorsAreFlaggedOpaqueOnesAreNot() {
    for color in ["rgba(1, 2, 3, 0.5)", "rgb(1 2 3 / 50%)", "rgba(1,2,3,0)"] {
      let parsed = parse("<span style=\"color: \(color)\">x</span>")
      #expect(parsed.hasUnsupportedContent, "\(color)")
      #expect(parsed.runs.first?.colorHex == "#010203")
    }
    for color in ["rgba(1, 2, 3, 1)", "rgb(1 2 3 / 100%)", "rgb(1, 2, 3)"] {
      #expect(!parse("<span style=\"color: \(color)\">x</span>").hasUnsupportedContent, "\(color)")
    }
  }

  @Test func unclosedHeadSwallowingTextIsFlagged() {
    let parsed = parse("<head>lost text")
    #expect(parsed.hasUnsupportedContent)
    #expect(!parse("<head></head>ok").hasUnsupportedContent)
  }

  @Test func decodesNamedAndNumericEntities() {
    let parsed = parse("&amp;&lt;&gt;&quot;&#65;&#x42;&nbsp;&#x1F600;")
    #expect(!parsed.hasUnsupportedContent)
    #expect(text(parsed) == "&<>\"AB\u{00A0}\u{1F600}")
  }

  @Test func brAndBlockElementsBecomeNewlines() {
    #expect(text(parse("a<br>b<br/>c")) == "a\nb\nc")
    #expect(text(parse("<div>a</div><div>b</div>\n<p>c</p>")) == "a\nb\nc")
    #expect(text(parse("<p>a<p>b")) == "a\nb")
  }

  @Test func tableListImageAnchorMarkUnsupported() {
    let cases = [
      "<table><tr><td>x</td></tr></table>", "<ul><li>x</li></ul>", "<ol><li>x</li></ol>",
      "x<img src=\"a.png\">", "<a href=\"https://e.com\">x</a>", "<h1>x</h1>", "<pre>x</pre>",
      "<code>x</code>", "<sub>x</sub>", "<s>x</s>",
      "<span style=\"background-color: red\">x</span>",
    ]
    for html in cases {
      let parsed = parse(html)
      #expect(parsed.hasUnsupportedContent, "\(html)")
      #expect(text(parsed).contains("x"), "\(html)")
    }
  }

  @Test func headStyleScriptContentIsDroppedWithoutFlagging() {
    let html =
      "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>T</title>"
      + "<style>p { color: red }</style><script>var a = '<b>';</script></head>"
      + "<body><!--StartFragment--><b>hi</b><!--EndFragment--></body></html>"
    let parsed = parse(html)
    #expect(!parsed.hasUnsupportedContent)
    #expect(parsed.runs == [StyledRun(text: "hi", bold: true)])
  }

  @Test func roundTripOfSupportedSubsetIsStable() {
    let runs = [
      StyledRun(text: "plain & <tag> \"q\" "),
      StyledRun(text: "bold\nline  two", bold: true),
      StyledRun(
        text: "styled", italic: true, underline: true, colorHex: "#123ABC",
        fontFamily: "Helvetica Neue", fontSizePt: 11.5),
      StyledRun(text: " tail\u{00A0}x\u{1F468}\u{200D}\u{1F469}"),
    ]
    let reparsed = parse(HTMLStyledRunCodec.html(from: runs))
    #expect(!reparsed.hasUnsupportedContent)
    #expect(reparsed.runs == runs)
  }

  @Test func hostileInputsNeverCrash() {
    let deep = String(repeating: "<b>", count: 10_000) + "x"
    let big = String(repeating: "a", count: 2_000_000)
    let inputs = [
      "<b><i>unclosed", "<<<<", "&#99999999999;", "&#0;", "a\u{0}b<b\u{0}>", deep, big,
      "<a href=\"", "<a x='", "<!--", "<!", "<", "&", "&#", "&#x;", "&#xD800;", "&amp",
      "</b></b></i>", "<script>never closed", "<span style=\"", "<span style=\";;;:::\">x",
      String(repeating: "<a \"", count: 50_000), String(repeating: "&#x", count: 50_000),
      String(repeating: "</p>", count: 200_000), "<p style=\"font-size: 99999999999999999999pt\">x",
    ]
    for input in inputs {
      let clock = ContinuousClock()
      let elapsed = clock.measure { _ = HTMLStyledRunCodec.parse(html: input) }
      #expect(elapsed < .seconds(2), "slow input of \(input.utf8.count) bytes")
    }
    #expect(parse("&#0;").hasUnsupportedContent)
    #expect(parse("&#99999999999;").hasUnsupportedContent)
    #expect(text(parse("<<<<")) == "<<<<")
    #expect(text(parse("<b><i>unclosed")) == "unclosed")
  }

  @Test func oversizedOrTooDeepInputIsFlaggedAndEmpty() {
    let expected = ParsedStyledText(runs: [], hasUnsupportedContent: true)
    let tooBig = String(repeating: "a", count: HTMLStyledRunCodec.maxInputBytes + 1)
    #expect(parse(tooBig) == expected)
    let atLimit = String(repeating: "a", count: HTMLStyledRunCodec.maxInputBytes)
    #expect(parse(atLimit).runs.count == 1)
    let depth = HTMLStyledRunCodec.maxNestingDepth
    let ok = String(repeating: "<b>", count: depth) + "x"
    #expect(text(parse(ok)) == "x")
    let deep = String(repeating: "<b>", count: depth + 1) + "x"
    #expect(parse(deep) == expected)
  }

  @Test func flattenAndRunsMappingRoundTripAcrossAdjacentStyles() {
    let runs = [
      StyledRun(text: "ab"),
      StyledRun(text: "cd", bold: true),
      StyledRun(text: "ef", italic: true),
      StyledRun(text: "gh", colorHex: "#FF0000"),
      StyledRun(text: "ij"),
    ]
    let (text, spans) = StyledRunMapping.flatten(runs)
    #expect(text == "abcdefghij")
    #expect(spans.map(\.start) == [2, 4, 6])
    #expect(spans.map(\.length) == [2, 2, 2])
    #expect(spans.allSatisfy { $0.run.text.isEmpty })
    #expect(StyledRunMapping.runs(text: text, spans: spans) == runs)
  }

  @Test func spanOffsetsCountUnicodeScalarsNotGraphemes() {
    // GtkTextBuffer offsets are Unicode code points: a ZWJ family is 5, "e" + acute is 2.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    let combined = "e\u{0301}"
    let runs = [
      StyledRun(text: family + combined),
      StyledRun(text: "x", bold: true),
    ]
    let (text, spans) = StyledRunMapping.flatten(runs)
    #expect(spans == [StyleSpan(start: 7, length: 1, run: StyledRun(text: "", bold: true))])
    #expect(StyledRunMapping.runs(text: text, spans: spans) == runs)
  }

  @Test func runsMappingToleratesHostileSpans() {
    let bold = StyledRun(text: "", bold: true)
    let spans = [
      StyleSpan(start: -5, length: 3, run: bold),
      StyleSpan(start: 1, length: Int.max, run: bold),
      StyleSpan(start: 10, length: 2, run: bold),
      StyleSpan(start: 0, length: Int.min, run: bold),
    ]
    let runs = StyledRunMapping.runs(text: "abcd", spans: spans)
    #expect(runs.map(\.text).joined() == "abcd")
    #expect(StyledRunMapping.runs(text: "", spans: spans).isEmpty)
  }

  @Test func randomizedInputsNeverCrashAndParsedRunsAreAFixedPoint() {
    let alphabet = [
      "<", ">", "/", "b", "i", "u", "p", "div", "span", "font", "br", "table", "td", "style=",
      "color:", "red", "#fa0", "font-size:", "12pt", "\"", "'", "=", ";", " ", "\n", "&", "#", "x",
      "amp;", "lt;", "65;", "nbsp;", "<!--", "-->", "\u{1F600}", "e\u{0301}", "\u{200D}", "\u{0}",
      "white-space:pre", "font-weight:bold", "text-decoration:underline",
    ]
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(truncatingIfNeeded: state >> 33)
    }
    for _ in 0..<3_000 {
      let html = (0..<(next() % 60)).map { _ in alphabet[next() % alphabet.count] }.joined()
      let parsed = parse(html)
      let again = parse(HTMLStyledRunCodec.html(from: parsed.runs))
      #expect(again.runs == parsed.runs, "not a fixed point for \(html.debugDescription)")
    }
  }
}
