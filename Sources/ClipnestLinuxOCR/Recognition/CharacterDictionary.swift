// CharacterDictionary.swift
//
// P6-C (Linux OCR): loads the character dictionary `CTCDecoder.greedyDecode`
// maps recognition class indices to. Split into a pure parse function (unit
// testable with synthetic file contents) and a thin disk-reading loader,
// matching this module's established pattern (see
// `MachineCapacityParsing`/`LiveMachineCapacityProber`'s own split).
import Foundation

public enum CharacterDictionary {

  /// Parses a dictionary file's contents: one character (or short token —
  /// PP-OCR's own dictionaries occasionally use short escape-like tokens)
  /// per line, in class-index-minus-one order (see
  /// `CTCDecoder.blankClassIndex`'s doc comment for the indexing
  /// convention). Trailing/leading blank lines are dropped; a line's
  /// internal content is used verbatim otherwise (a dictionary character
  /// could legitimately BE a space, so lines are only trimmed of the
  /// line-ending itself, never of leading/trailing spaces within the
  /// line).
  public static func parse(fileContents: String) -> [String] {
    fileContents
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  /// Loads and parses the dictionary at `path`. Returns an empty array
  /// (never crashes) if the file is missing/unreadable — callers must
  /// treat an empty dictionary as "recognition unavailable," exactly like
  /// any other best-effort OCR failure.
  public static func load(path: String) -> [String] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return parse(fileContents: contents)
  }
}
