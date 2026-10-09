// GTKRowDisplayTextTests.swift
//
// T-ROWLINES1. See GTKKeyEventMappingTests.swift's top doc comment for the
// ClipnestPlatformLinuxTests -> ClipnestGTK manifest-dependency note.
import Testing

@testable import ClipnestGTK

@Suite("RowDisplayText")
struct GTKRowDisplayTextTests {
  @Test("Newlines, tabs and runs of spaces collapse to single spaces")
  func collapsesWhitespace() {
    #expect(RowDisplayText.collapsed("a\nb\t\tc   d\r\ne") == "a b c d e")
  }

  @Test("Leading and trailing whitespace is dropped")
  func trims() {
    #expect(RowDisplayText.collapsed("\n\n  hello world \n") == "hello world")
  }

  @Test("A 200-line copy becomes one bounded paragraph")
  func twoHundredLines() {
    let text = (1...200).map { "line number \($0)" }.joined(separator: "\n")
    let result = RowDisplayText.collapsed(text)
    #expect(!result.contains("\n"))
    #expect(result.count <= RowDisplayText.maxCharacters)
    #expect(result.hasPrefix("line number 1 line number 2"))
  }

  @Test("A very long single line is cut at the cap")
  func longSingleLine() {
    let result = RowDisplayText.collapsed(String(repeating: "x", count: 100_000))
    #expect(result.count == RowDisplayText.maxCharacters)
  }

  @Test("Empty and whitespace-only text yield an empty string")
  func empty() {
    #expect(RowDisplayText.collapsed("") == "")
    #expect(RowDisplayText.collapsed(" \n\t ") == "")
  }

  @Test("The cap is never exceeded, collapse spaces included, for multi-line and emoji input")
  func capHoldsForAllInputs() {
    let multi = (1...500).map { "word\($0)" }.joined(separator: "\n")
    let emoji = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ", count: 2000)
    let cjk = String(repeating: "\u{6F22}\u{5B57} ", count: 5000)
    for input in [multi, emoji, cjk] {
      for cap in [1, 2, 7, RowDisplayText.maxCharacters] {
        let result = RowDisplayText.collapsed(input, maxCharacters: cap)
        #expect(result.count <= cap)
        #expect(!result.hasSuffix(" "))
      }
    }
  }
}
