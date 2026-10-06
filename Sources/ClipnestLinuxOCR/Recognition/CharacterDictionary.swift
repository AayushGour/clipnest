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

  /// PaddleOCR's own `use_space_char=True` postprocessing convention (see
  /// `ppocr/postprocess/rec_postprocess.py`'s `BaseRecLabelDecode.__init__`):
  /// after the dictionary FILE's own characters are loaded, a single
  /// literal space is appended — BEFORE `CTCLabelDecode.add_special_char`
  /// prepends `blank`, i.e. class layout is `[blank] + dict.txt lines +
  /// [" "]`. PP-OCRv5's `rec.onnx` was exported with this exact
  /// convention: 18385 output classes = 1 blank + 18383 `dict.txt` lines +
  /// 1 space (verified against the real vendored `rec.onnx`/`dict.txt` —
  /// see `packaging/linux/vendor/ppocr-models/SOURCE.md`). `dict.txt`
  /// itself never contains a trailing space line — the space is injected
  /// here, at load time, exactly mirroring PaddleOCR's own postprocessing,
  /// rather than baked into `parse`'s pure "one line per line" contract
  /// (this keeps `parse` a literal reflection of the file, matching its
  /// own doc comment and existing tests).
  ///
  /// Before this fix, `dict.txt`'s 18383 characters plus `CTCDecoder`'s
  /// reserved blank (class 0) accounted for only 18384 of `rec.onnx`'s
  /// 18385 classes — the model's real space class (18385) always fell
  /// outside `CTCDecoder.greedyDecode`'s `dictIndex < dictionary.count`
  /// bounds check and was silently skipped, concatenating every word in a
  /// line with no separator (measured: `"brown fox jumps"` decoded as
  /// `"brownfoxjumps"`). Appending the space here — so `dictionary.count`
  /// is 18384 and the space occupies the correct final `dictIndex`, 18383
  /// — closes that gap without touching `CTCDecoder` at all: its existing
  /// bounds check was already correct for whatever dictionary it's given,
  /// the dictionary itself was one entry short.
  static let spaceCharacter = " "

  /// Appends `spaceCharacter` after `dictionary`'s own entries. Pure and
  /// independently testable without a real file — see
  /// `CharacterDictionaryTests` for the exact class-index arithmetic this
  /// restores.
  static func appendingSpaceCharacter(to dictionary: [String]) -> [String] {
    dictionary + [spaceCharacter]
  }

  /// Loads and parses the dictionary at `path`, then applies
  /// `appendingSpaceCharacter(to:)`. Returns an empty array (never
  /// crashes) if the file is missing/unreadable, or if it parses to zero
  /// characters — callers must treat an empty dictionary as "recognition
  /// unavailable," exactly like any other best-effort OCR failure (an
  /// empty dictionary plus a lone appended space would otherwise look
  /// like a working, if useless, one-character dictionary).
  public static func load(path: String) -> [String] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let dictionary = parse(fileContents: contents)
    guard !dictionary.isEmpty else { return [] }
    return appendingSpaceCharacter(to: dictionary)
  }
}
