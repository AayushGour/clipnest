// OCRCharacterDictionaryTests.swift
//
// P6-C (Linux OCR): unit tests for `CharacterDictionary.parse` — pure
// string parsing, no filesystem/ONNX Runtime dependency (matching this
// module's established "feed synthetic file contents" testing pattern —
// see `OCRMachineCapacityProberTests`).
//
// T-OCR9 (P1 fix): also pins the `use_space_char=True` space-append
// convention `load(path:)` now applies — see `CharacterDictionary
// .appendingSpaceCharacter(to:)`'s doc comment for the exact upstream
// (`ppocr/postprocess/rec_postprocess.py`) reference this matches.
import Foundation
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

  @Test("appendingSpaceCharacter appends a single literal space AFTER the dictionary's own entries")
  func appendingSpaceCharacterAppendsAfterExistingEntries() {
    #expect(
      CharacterDictionary.appendingSpaceCharacter(to: ["a", "b", "c"]) == ["a", "b", "c", " "])
  }

  @Test("appendingSpaceCharacter on an empty dictionary yields just the space")
  func appendingSpaceCharacterOnEmptyDictionary() {
    #expect(CharacterDictionary.appendingSpaceCharacter(to: []) == [" "])
  }

  @Test(
    "load(path:) appends the space character after the file's own lines — matches rec.onnx's 18385 classes = 1 blank + 18383 dict.txt lines + 1 space"
  )
  func loadAppendsSpaceCharacter() throws {
    let path = NSTemporaryDirectory() + "clipnest-ocr-dict-test-\(UUID().uuidString).txt"
    try "a\nb\nc\n".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(CharacterDictionary.load(path: path) == ["a", "b", "c", " "])
  }

  @Test("load(path:) of a file that parses to zero characters stays empty — never a lone space")
  func loadOfEmptyFileStaysEmpty() throws {
    let path = NSTemporaryDirectory() + "clipnest-ocr-dict-test-\(UUID().uuidString).txt"
    try "\n\n\n".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(CharacterDictionary.load(path: path).isEmpty)
  }

  @Test(
    "End-to-end: CTCDecoder.greedyDecode correctly reproduces a space between words once the dictionary includes the appended space class — pins T-OCR9's measured regression (\"brown fox jumps\" no longer decodes as \"brownfoxjumps\")"
  )
  func greedyDecodeWithAppendedSpaceKeepsWordsSeparated() {
    // Tiny synthetic dictionary standing in for dict.txt's 18383 real
    // lines: ["b","r","o","w","n","f","x","j","u","m","p","s"] (index 0
    // through 11, so class index = dictIndex + 1, i.e. 1 through 12).
    let dictionary = CharacterDictionary.appendingSpaceCharacter(
      to: ["b", "r", "o", "w", "n", "f", "x", "j", "u", "m", "p", "s"])
    // Space is the 13th (0-based index 12) entry -> class index 13.
    let spaceClassIndex = dictionary.count  // dictIndex (12) + 1 == count (13).

    func classIndices(for word: String) -> [Int] {
      word.map { char in dictionary.firstIndex(of: String(char))! + 1 }
    }

    // "brown" + space + "fox" + space + "jumps", each letter run collapsed
    // to a single timestep the way CTCDecoder.argmax's per-timestep output
    // already is — greedyDecode collapses consecutive duplicates first, so
    // repeating the space class would collapse to one space regardless.
    let classes =
      classIndices(for: "brown") + [spaceClassIndex] + classIndices(for: "fox")
      + [spaceClassIndex] + classIndices(for: "jumps")

    let result = CTCDecoder.greedyDecode(classIndices: classes, dictionary: dictionary)
    #expect(result == "brown fox jumps")
  }
}
