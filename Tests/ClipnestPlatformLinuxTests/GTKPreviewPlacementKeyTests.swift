// GTKPreviewPlacementKeyTests.swift
//
// T-PREVIEWJUMP1 follow-up. See GTKKeyEventMappingTests.swift's top doc comment
// for the ClipnestPlatformLinuxTests -> ClipnestGTK manifest-dependency note.
import Foundation
import Testing

@testable import ClipnestGTK

@Suite("PreviewPlacementKey")
struct GTKPreviewPlacementKeyTests {
  private let id = UUID()

  private func key(_ id: UUID, y: Int32 = 100) -> PreviewPlacementKey {
    PreviewPlacementKey(targetID: id, x: 1, y: y, width: 756, height: 34)
  }

  @Test("Nothing on screen: no teardown needed")
  func nothingShown() {
    #expect(!PreviewPlacementKey.needsRemap(shown: nil, new: key(id)))
  }

  @Test("Same target and same anchor: leave the popup alone")
  func unchanged() {
    #expect(!PreviewPlacementKey.needsRemap(shown: key(id), new: key(id)))
  }

  @Test("A different target re-maps")
  func targetChanged() {
    #expect(PreviewPlacementKey.needsRemap(shown: key(id), new: key(UUID())))
  }

  @Test("The same target at a different anchor re-maps")
  func anchorChanged() {
    #expect(PreviewPlacementKey.needsRemap(shown: key(id), new: key(id, y: 140)))
  }
}
