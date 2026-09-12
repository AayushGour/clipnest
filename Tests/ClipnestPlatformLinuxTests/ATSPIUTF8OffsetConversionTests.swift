import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("UTF8OffsetConversion")
struct UTF8OffsetConversionTests {
  @Test("ASCII text: byte count equals scalar count")
  func asciiByteCountEqualsScalarCount() {
    #expect(UTF8OffsetConversion.utf8ByteCount(of: "hello") == 5)
  }

  @Test(
    "non-ASCII text: byte count exceeds scalar/character count — the exact off-by-N InsertText's length would hit if character count were used instead"
  )
  func nonAsciiByteCountExceedsCharacterCount() {
    let text = "héllo"  // 'é' is U+00E9: 1 scalar, 1 Character, but 2 UTF-8 bytes.
    #expect(text.count == 5)
    #expect(text.unicodeScalars.count == 5)
    #expect(UTF8OffsetConversion.utf8ByteCount(of: text) == 6)
  }

  @Test("emoji text: byte count is far larger than scalar count")
  func emojiByteCount() {
    let text = "🎉"  // U+1F389: 1 scalar, 4 UTF-8 bytes.
    #expect(UTF8OffsetConversion.utf8ByteCount(of: text) == 4)
  }

  @Test(
    "scalarCount counts Unicode scalars, matching AT-SPI's own offset unit -- verified against a real at-spi2-core bus (see ATSPITextAccessor.replaceSelectedText's doc comment), not UTF-16 code units or UTF-8 bytes"
  )
  func scalarCountMatchesUnicodeScalarView() {
    #expect(UTF8OffsetConversion.scalarCount(of: "hello") == 5)
    // 'é' is 1 scalar, 2 UTF-8 bytes -- scalarCount must track the former.
    #expect(UTF8OffsetConversion.scalarCount(of: "héllo") == 5)
    // An astral emoji is 1 Unicode scalar but 2 UTF-16 code units and 4
    // UTF-8 bytes -- a wrong assumption using either of those would be
    // caught here.
    #expect(UTF8OffsetConversion.scalarCount(of: "😀Y") == 2)
  }

  @Test(
    "scalarCount counts scalars, not extended grapheme clusters — a base+combining-mark sequence is 1 `Character` but 2 scalars, and the live at-spi2-core bus was confirmed to count it as 2 offset-addressable units, not 1"
  )
  func scalarCountDiffersFromCharacterCountForCombiningSequences() {
    let text = "e\u{0301}"  // 'e' + COMBINING ACUTE ACCENT: 1 Character, 2 scalars.
    #expect(text.count == 1)
    #expect(UTF8OffsetConversion.scalarCount(of: text) == 2)
  }

  @Test("stringIndex(atScalarOffset:) walks scalars, not extended grapheme clusters")
  func stringIndexWalksScalars() {
    // "é" here is 'e' + combining acute accent: 1 Character, 2 scalars.
    let text = "e\u{0301}bc"
    guard let index = UTF8OffsetConversion.stringIndex(atScalarOffset: 1, in: text) else {
      Issue.record("expected an index")
      return
    }
    #expect(text.unicodeScalars[index] == "\u{0301}")
  }

  @Test("stringIndex out of range returns nil rather than crashing")
  func stringIndexOutOfRangeReturnsNil() {
    #expect(UTF8OffsetConversion.stringIndex(atScalarOffset: -1, in: "abc") == nil)
    #expect(UTF8OffsetConversion.stringIndex(atScalarOffset: 100, in: "abc") == nil)
  }

  @Test("substring extracts the AT-SPI-reported selection range by scalar offsets")
  func substringExtractsRange() {
    #expect(
      UTF8OffsetConversion.substring(in: "hello world", startScalarOffset: 6, endScalarOffset: 11)
        == "world")
  }

  @Test("substring returns nil when start exceeds end")
  func substringNilWhenStartExceedsEnd() {
    #expect(
      UTF8OffsetConversion.substring(in: "hello", startScalarOffset: 4, endScalarOffset: 1) == nil)
  }

  @Test("substring at a zero-length range returns an empty string, not nil")
  func substringZeroLengthRange() {
    #expect(
      UTF8OffsetConversion.substring(in: "hello", startScalarOffset: 2, endScalarOffset: 2) == "")
  }
}
