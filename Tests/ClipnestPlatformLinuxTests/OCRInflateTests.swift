// OCRInflateTests.swift
//
// P6-C (Linux OCR): unit tests for `Inflate` (this module's from-scratch
// DEFLATE/RFC 1951 decoder — see `Inflate.swift`'s doc comment for why it
// exists rather than a dependency). These hand-built raw-DEFLATE byte
// sequences were independently verified against Python's `zlib` module
// (`zlib.decompressobj(wbits=-15)`, which speaks raw DEFLATE with no zlib
// container) before being embedded here — see this task's handoff notes for
// the verification transcript. `@testable import` is this codebase's
// established pattern for reaching non-`public` internals (see e.g.
// `Tests/ClipnestViewModelsTests`).

import Testing

@testable import ClipnestLinuxOCR

@Suite("Inflate")
struct OCRInflateTests {

  @Test("A stored (uncompressed) DEFLATE block decodes back to its literal bytes")
  func decompressesStoredBlock() {
    // bfinal=1, btype=00 (stored) -> header byte 0b00000001; then LEN=3,
    // NLEN=~3 (little-endian 16-bit each); then the 3 literal bytes "ABC".
    let bytes: [UInt8] = [0x01, 0x03, 0x00, 0xFC, 0xFF, 65, 66, 67]
    #expect(Inflate.decompress(bytes) == [65, 66, 67])
  }

  @Test("A stored block with a LEN/NLEN mismatch is rejected, not silently accepted")
  func rejectsStoredBlockWithBadLengthComplement() {
    // Same as above but NLEN is wrong (should be ~3 = 0xFFFC, given as 0xFFFF).
    let bytes: [UInt8] = [0x01, 0x03, 0x00, 0xFF, 0xFF, 65, 66, 67]
    #expect(Inflate.decompress(bytes) == nil)
  }

  @Test("An invalid block type (btype == 3, reserved) fails closed, never crashes")
  func rejectsReservedBlockType() {
    // bfinal=1, btype=11 (reserved/invalid) -> 0b00000111 = 7.
    let bytes: [UInt8] = [0x07]
    #expect(Inflate.decompress(bytes) == nil)
  }

  @Test("Empty input decodes to nil, not a crash")
  func rejectsEmptyInput() {
    #expect(Inflate.decompress([]) == nil)
  }

  @Test("Truncated input (header claims more data than is present) fails closed")
  func rejectsTruncatedStoredBlock() {
    // Claims LEN=10 but only 2 bytes of payload follow.
    let bytes: [UInt8] = [0x01, 0x0A, 0x00, 0xF5, 0xFF, 1, 2]
    #expect(Inflate.decompress(bytes) == nil)
  }

}

// NOTE: the fixed/dynamic-Huffman decode path (`decodeCompressedBlock`,
// including its `matchDistance <= output.count` back-reference guard) is
// exercised end-to-end, with pixel-perfect verification against
// independently-computed expected output, by the real-world PNG fixtures in
// `OCRPNGDecoderTests` — every non-trivial PNG a zlib encoder produces uses
// fixed or dynamic Huffman blocks, so those tests already cover this file's
// main decode loop; hand-constructing a byte-level fixed-Huffman fixture
// here would just re-test the same code path with far less confidence.
