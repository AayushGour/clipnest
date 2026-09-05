// CTCDecoder.swift
//
// CTC (Connectionist Temporal Classification) decoding for PP-OCRv5's CRNN
// recognition head. The CRNN outputs one class probability per timestep,
// and this module provides greedy decoding: collapse consecutive duplicates,
// drop blanks, then map class indices to dictionary characters. Model output
// corruption or mismatches never crash (this module's purpose is best-effort
// recognition in a background pass); invalid indices are silently skipped.

/// Greedy CTC decoding for PP-OCRv5's CRNN recognition head. CTC ("Connectionist
/// Temporal Classification") models emit one class index per timestep,
/// including a reserved "blank" class for "no new character here" — the
/// standard decode collapses consecutive repeats (multiple timesteps often
/// vote for the same character) and then drops every remaining blank.
public enum CTCDecoder {
  /// PP-OCR's CTC head reserves class index 0 for blank; dictionary
  /// character N (0-based) is class index N+1. Named rather than
  /// hardcoded at each call site (no magic numbers).
  public static let blankClassIndex = 0

  /// Collapses consecutive duplicate indices, drops every remaining
  /// `blankIndex`, then maps each surviving index `i` to `dictionary[i - 1]`
  /// and concatenates. Any index that resolves outside `dictionary`'s valid
  /// range (i.e. `i < 1` after the blank-drop, or `i - 1 >= dictionary.count`)
  /// is SKIPPED rather than crashing — a corrupt/mismatched model output
  /// must never crash a background OCR pass (this module's whole raison
  /// d'être is best-effort, never-blocking recognition; see the
  /// `TextRecognizing.recognizeText` "never throws" contract in
  /// `Sources/ClipnestCore/OCR/TextRecognizing.swift`).
  public static func greedyDecode(
    classIndices: [Int], dictionary: [String], blankIndex: Int = blankClassIndex
  ) -> String {
    // Collapse consecutive duplicates: emit the first of each run.
    var collapsed: [Int] = []
    var lastIndex: Int? = nil
    for index in classIndices {
      if index != lastIndex {
        collapsed.append(index)
        lastIndex = index
      }
    }

    // Drop blanks and map to dictionary.
    var result = ""
    for index in collapsed {
      guard index != blankIndex else { continue }
      let dictIndex = index - 1
      guard dictIndex >= 0, dictIndex < dictionary.count else { continue }
      result.append(dictionary[dictIndex])
    }

    return result
  }

  /// Per-timestep argmax over `logits` (shape `[timestep][class]`, raw
  /// scores or probabilities — argmax is invariant to any monotonic
  /// transform so softmax is unnecessary here). Returns one class index per
  /// timestep. An empty inner array (a pathological/corrupt row) yields
  /// `-1` for that timestep (safely skipped downstream by `greedyDecode`'s
  /// range check, since `-1 < 1`).
  public static func argmax(logits: [[Float]]) -> [Int] {
    logits.map { row in
      guard let (maxIdx, _) = row.enumerated().max(by: { $0.element < $1.element }) else {
        return -1
      }
      return maxIdx
    }
  }
}
