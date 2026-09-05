import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("UTF8OffsetConversion")
struct UTF8OffsetConversionTests {
  @Test("ASCII text: byte count equals scalar count")
  func asciiByteCountEqualsScalarCount() {
    #expect(UTF8OffsetConversion.utf8ByteCount(of: "hello") == 5)
  }

  @Test("non-ASCII text: byte count exceeds scalar/character count — the exact off-by-N InsertText's length would hit if character count were used instead")
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
    #expect(UTF8OffsetConversion.substring(in: "hello world", startScalarOffset: 6, endScalarOffset: 11) == "world")
  }

  @Test("substring returns nil when start exceeds end")
  func substringNilWhenStartExceedsEnd() {
    #expect(UTF8OffsetConversion.substring(in: "hello", startScalarOffset: 4, endScalarOffset: 1) == nil)
  }

  @Test("substring at a zero-length range returns an empty string, not nil")
  func substringZeroLengthRange() {
    #expect(UTF8OffsetConversion.substring(in: "hello", startScalarOffset: 2, endScalarOffset: 2) == "")
  }
}
