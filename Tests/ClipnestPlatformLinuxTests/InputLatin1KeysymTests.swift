import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("Latin1Keysym")
struct Latin1KeysymTests {
  @Test("ASCII letter keysym equals its Unicode code point")
  func asciiLetterMatchesCodePoint() {
    #expect(Latin1Keysym.keysym(for: "v") == 0x76)
    #expect(Latin1Keysym.keysym(for: "V") == 0x56)
    #expect(Latin1Keysym.keysym(for: "c") == 0x63)
  }

  @Test("boundary of the Latin-1 range is inclusive")
  func rangeBoundaries() {
    #expect(Latin1Keysym.keysym(for: "\u{20}") == 0x20)
    #expect(Latin1Keysym.keysym(for: "\u{FF}") == 0xFF)
  }

  @Test("outside the Latin-1 range returns nil, never a guess")
  func outsideRangeReturnsNil() {
    #expect(Latin1Keysym.keysym(for: "\u{1F600}") == nil)  // emoji
    #expect(Latin1Keysym.keysym(for: "\u{100}") == nil)
  }

  @Test("a multi-scalar Character (e.g. combining sequence) returns nil")
  func multiScalarCharacterReturnsNil() {
    let combining: Character = "e\u{0301}"  // e + combining acute accent
    #expect(Latin1Keysym.keysym(for: combining) == nil)
  }
}
