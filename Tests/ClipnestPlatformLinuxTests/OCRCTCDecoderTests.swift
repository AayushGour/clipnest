import Foundation
import Testing

@testable import ClipnestLinuxOCR

@Suite("CTC Decoder")
struct OCRCTCDecoderTests {
  private let defaultDictionary = ["a", "b", "c"]

  @Test("Greedy decode collapses consecutive duplicates then drops blanks")
  func greedyDecodeBasic() {
    // classIndices: [0,1,1,2,0,0,3], blank=0, dict=["a","b","c"]
    // After collapse: [0,1,2,0,3]
    // After drop blanks: [1,2,3]
    // After mapping (i-1): [a,b,c]
    let result = CTCDecoder.greedyDecode(
      classIndices: [0, 1, 1, 2, 0, 0, 3],
      dictionary: defaultDictionary,
      blankIndex: 0
    )
    #expect(result == "abc")
  }

  @Test("All-blank input yields empty string")
  func greedyDecodeAllBlanks() {
    let result = CTCDecoder.greedyDecode(
      classIndices: [0, 0, 0],
      dictionary: defaultDictionary,
      blankIndex: 0
    )
    #expect(result == "")
  }

  @Test("Empty input yields empty string")
  func greedyDecodeEmpty() {
    let result = CTCDecoder.greedyDecode(
      classIndices: [],
      dictionary: defaultDictionary,
      blankIndex: 0
    )
    #expect(result == "")
  }

  @Test("Out-of-range index is skipped, not crashed")
  func greedyDecodeOutOfRange() {
    // classIndices: [1, 99, 2], dict=["a","b","c"]
    // After collapse: [1, 99, 2]
    // After drop blanks: [1, 99, 2]
    // After mapping: [a, skip, b] (99-1=98 is out of range)
    let result = CTCDecoder.greedyDecode(
      classIndices: [1, 99, 2],
      dictionary: defaultDictionary,
      blankIndex: 0
    )
    #expect(result == "ab")
  }

  @Test("Custom non-zero blankIndex works correctly")
  func greedyDecodeCustomBlank() {
    // classIndices: [1, 2, 5, 3], blank=5, dict=["a","b","c"]
    // After collapse: [1, 2, 5, 3]
    // After drop blanks (5): [1, 2, 3]
    // After mapping (i-1): [a, b, c]
    let result = CTCDecoder.greedyDecode(
      classIndices: [1, 2, 5, 3],
      dictionary: defaultDictionary,
      blankIndex: 5
    )
    #expect(result == "abc")
  }

  @Test("Argmax on simple logits yields correct class indices")
  func argmaxBasic() {
    let logits: [[Float]] = [
      [0.1, 0.9],
      [0.8, 0.2],
    ]
    let result = CTCDecoder.argmax(logits: logits)
    #expect(result == [1, 0])
  }

  @Test("Empty inner array yields -1 for that timestep")
  func argmaxEmptyRow() {
    let logits: [[Float]] = [
      [0.1, 0.9],
      [],
      [0.8, 0.2],
    ]
    let result = CTCDecoder.argmax(logits: logits)
    #expect(result == [1, -1, 0])
  }

  @Test("Single row with multiple classes works")
  func argmaxMultiClass() {
    let logits: [[Float]] = [
      [0.2, 0.5, 0.1, 0.9, 0.3]
    ]
    let result = CTCDecoder.argmax(logits: logits)
    #expect(result == [3])
  }
}
