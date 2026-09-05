import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("IncrTransferReassembler")
struct IncrTransferReassemblerTests {
  @Test("Reassembles several chunks into one buffer, completing on the zero-length terminator")
  func reassemblesMultipleChunks() throws {
    let reassembler = IncrTransferReassembler()

    #expect(try reassembler.append(Data([0x01, 0x02]), elapsedSinceTransferStart: 0) == nil)
    #expect(try reassembler.append(Data([0x03, 0x04]), elapsedSinceTransferStart: 1) == nil)
    let result = try reassembler.append(Data(), elapsedSinceTransferStart: 2)

    #expect(result == Data([0x01, 0x02, 0x03, 0x04]))
  }

  @Test("An immediate zero-length chunk completes with an empty buffer")
  func immediateZeroLengthChunkCompletesEmpty() throws {
    let reassembler = IncrTransferReassembler()
    let result = try reassembler.append(Data(), elapsedSinceTransferStart: 0)
    #expect(result == Data())
  }

  @Test("Throws .timedOut once elapsed time exceeds the configured timeout")
  func throwsOnTimeout() {
    let reassembler = IncrTransferReassembler()
    #expect(throws: IncrTransferError.timedOut) {
      try reassembler.append(
        Data([0x01]),
        elapsedSinceTransferStart: LinuxClipboardConstants.incrTransferTimeout + 1)
    }
  }

  @Test("A chunk landing exactly at the timeout boundary is still accepted")
  func acceptsChunkAtExactTimeoutBoundary() throws {
    let reassembler = IncrTransferReassembler()
    let result = try reassembler.append(
      Data([0x01]), elapsedSinceTransferStart: LinuxClipboardConstants.incrTransferTimeout)
    #expect(result == nil)
  }

  @Test("Throws .tooLarge once the reassembled total would exceed the size ceiling")
  func throwsWhenExceedingSizeCeiling() {
    let reassembler = IncrTransferReassembler()
    let oversizedChunk = Data(count: LinuxClipboardConstants.incrTransferMaxTotalBytes + 1)
    #expect(throws: IncrTransferError.tooLarge) {
      try reassembler.append(oversizedChunk, elapsedSinceTransferStart: 0)
    }
  }

  @Test("A transfer landing exactly at the size ceiling succeeds")
  func acceptsExactSizeCeiling() throws {
    let reassembler = IncrTransferReassembler()
    let exactChunk = Data(count: LinuxClipboardConstants.incrTransferMaxTotalBytes)
    #expect(try reassembler.append(exactChunk, elapsedSinceTransferStart: 0) == nil)
    let result = try reassembler.append(Data(), elapsedSinceTransferStart: 1)
    #expect(result?.count == LinuxClipboardConstants.incrTransferMaxTotalBytes)
  }

  @Test("Calling append again after completion is idempotent, returning the same buffer")
  func idempotentAfterCompletion() throws {
    let reassembler = IncrTransferReassembler()
    _ = try reassembler.append(Data([0xAA]), elapsedSinceTransferStart: 0)
    let first = try reassembler.append(Data(), elapsedSinceTransferStart: 1)
    let second = try reassembler.append(Data([0xBB]), elapsedSinceTransferStart: 2)
    #expect(first == second)
    #expect(second == Data([0xAA]))
  }
}
