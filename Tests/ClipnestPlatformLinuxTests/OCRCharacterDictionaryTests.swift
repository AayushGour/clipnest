// OCRCharacterDictionaryTests.swift
//
// P6-C (Linux OCR): unit tests for `CharacterDictionary.parse` — pure
// string parsing, no filesystem/ONNX Runtime dependency (matching this
// module's established "feed synthetic file contents" testing pattern —
// see `OCRMachineCapacityProberTests`).
import Testing

@testable import ClipnestLinuxOCR

@Suite("CharacterDictionary")
struct OCRCharacterDictionaryTests {

  @Test("Parses one character per line, in order")
  func parsesOneCharacterPerLine() {
    let contents = "a\nb\nc\n"
    #expect(CharacterDictionary.parse(fileContents: contents) == ["a", "b", "c"])
  }

  @Test("Drops trailing/leading blank lines but keeps internal content verbatim")
  func dropsBlankLinesOnly() {
    let contents = "\n\na\nb\n\n"
    #expect(CharacterDictionary.parse(fileContents: contents) == ["a", "b"])
  }

  @Test("Empty input parses to an empty dictionary")
  func emptyInputParsesEmpty() {
    #expect(CharacterDictionary.parse(fileContents: "").isEmpty)
  }

  @Test("Loading a nonexistent path returns an empty dictionary, never crashes")
  func loadingMissingFileReturnsEmpty() {
    #expect(CharacterDictionary.load(path: "/nonexistent/path/dict.txt").isEmpty)
  }
}
