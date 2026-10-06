import Foundation

/// Errors an in-progress `IncrTransferReassembler` can throw.
public enum IncrTransferError: Error, Equatable, Sendable {
  /// No new chunk arrived within `LinuxClipboardConstants.incrTransferTimeout`
  /// of the transfer's start.
  case timedOut
  /// The reassembled total would exceed
  /// `LinuxClipboardConstants.incrTransferMaxTotalBytes`.
  case tooLarge
}

/// Pure ICCCM section 2.7.2 INCR-transfer reassembly: appends successive
/// property-read chunks into one buffer, completing on the first
/// zero-length chunk (INCR's defined end-of-transfer marker).
///
/// No X11, no real clock, no threading — the real `X11ClipboardConnection`
/// (unverifiable without a live display) is the only caller that feeds this
/// real property reads and a real elapsed-time clock; tests feed it
/// synthetic chunks and synthetic elapsed times instead (see
/// `IncrTransferReassemblerTests`).
public final class IncrTransferReassembler {
  private var buffer = Data()
  private var isComplete = false

  public init() {}

  /// Appends one chunk read from the transfer's destination property.
  ///
  /// - Parameters:
  ///   - chunk: The bytes most recently read from the property (already
  ///     stripped of any protocol framing — just the raw payload slice).
  ///     An empty `Data` signals the owner has finished (ICCCM 2.7.2).
  ///   - elapsedSinceTransferStart: Wall-clock time elapsed since this
  ///     transfer began (the INCR property's type first observed) —
  ///     supplied by the caller so this type has no real-clock dependency
  ///     of its own and stays deterministically testable.
  /// - Returns: The fully reassembled `Data` once the zero-length
  ///   terminator chunk has been appended; `nil` while more chunks are
  ///   still expected.
  /// - Throws: `IncrTransferError.timedOut` if `elapsedSinceTransferStart`
  ///   exceeds `LinuxClipboardConstants.incrTransferTimeout`;
  ///   `.tooLarge` if the reassembled total would exceed
  ///   `LinuxClipboardConstants.incrTransferMaxTotalBytes`. Both leave the
  ///   reassembler in a terminal, unusable state — a caller that catches
  ///   either must abort the transfer, never call `append` again on the
  ///   same instance.
  @discardableResult
  public func append(_ chunk: Data, elapsedSinceTransferStart: TimeInterval) throws -> Data? {
    guard !isComplete else { return buffer }

    guard elapsedSinceTransferStart <= LinuxClipboardConstants.incrTransferTimeout else {
      isComplete = true
      throw IncrTransferError.timedOut
    }

    guard chunk.count > 0 else {
      isComplete = true
      return buffer
    }

    guard buffer.count + chunk.count <= LinuxClipboardConstants.incrTransferMaxTotalBytes else {
      isComplete = true
      throw IncrTransferError.tooLarge
    }

    buffer.append(chunk)
    return nil
  }
}
