// PreviewPlacementKey.swift
//
// T-PREVIEWJUMP1 follow-up: decides whether an already-shown preview popup has
// to be torn down and re-mapped. Re-mapping blinks, so it only happens when the
// target or the anchor actually changed; an update that changes neither (for
// example hover to selection on the same row) leaves the popup alone.
import Foundation

public struct PreviewPlacementKey: Equatable {
  public let targetID: UUID
  public let x: Int32
  public let y: Int32
  public let width: Int32
  public let height: Int32

  public init(targetID: UUID, x: Int32, y: Int32, width: Int32, height: Int32) {
    self.targetID = targetID
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// `true` when the popup that is on screen (`shown`) must be popped down
  /// before showing `new`. Nothing on screen means nothing to tear down.
  public static func needsRemap(shown: PreviewPlacementKey?, new: PreviewPlacementKey) -> Bool {
    guard let shown else { return false }
    return shown != new
  }
}
