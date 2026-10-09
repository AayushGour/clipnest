// GTKPreviewAnchorTests.swift
//
// See GTKKeyEventMappingTests.swift's top doc comment for the
// `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency note.
import Testing

@testable import ClipnestGTK

@Suite("PreviewAnchor")
struct GTKPreviewAnchorTests {
  @Test("Band spans the whole window width at the row's height")
  func spansWindow() {
    let band = PreviewAnchor.band(windowLeft: -12, windowWidth: 420, rowTop: 96, rowHeight: 44)
    #expect(band == PreviewAnchor.Band(x: -12, y: 96, width: 420, height: 44))
  }

  @Test("Unallocated widgets never yield an empty rect")
  func clampsEmpty() {
    let band = PreviewAnchor.band(windowLeft: 0, windowWidth: 0, rowTop: 0, rowHeight: 0)
    #expect(band.width == 1)
    #expect(band.height == 1)
  }

  @Test("Gap is positive")
  func gapPositive() {
    #expect(PreviewAnchor.gap > 0)
  }
}
