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
}
