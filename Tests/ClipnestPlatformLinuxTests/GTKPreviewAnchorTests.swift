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
    let band = PreviewAnchor.band(
      windowLeft: -12, windowWidth: 420, rowTop: 96, rowHeight: 44, visibleTop: 0,
      visibleHeight: 400)
    #expect(band == PreviewAnchor.Band(x: -12, y: 96, width: 420, height: 44))
  }

  @Test("Unallocated widgets never yield an empty rect")
  func clampsEmpty() {
    let band = PreviewAnchor.band(
      windowLeft: 0, windowWidth: 0, rowTop: 0, rowHeight: 0, visibleTop: 0, visibleHeight: 0)
    #expect(band.width == 1)
    #expect(band.height == 1)
  }

  @Test("A row clipped by the viewport bottom is clipped to the viewport")
  func clipsBottom() {
    let band = PreviewAnchor.band(
      windowLeft: 0, windowWidth: 400, rowTop: 380, rowHeight: 44, visibleTop: 0,
      visibleHeight: 400)
    #expect(band.y == 380)
    #expect(band.height == 20)
  }

  @Test("A row clipped by the viewport top is clipped to the viewport")
  func clipsTop() {
    let band = PreviewAnchor.band(
      windowLeft: 0, windowWidth: 400, rowTop: -20, rowHeight: 44, visibleTop: 0,
      visibleHeight: 400)
    #expect(band.y == 0)
    #expect(band.height == 24)
  }

  @Test("A row wholly outside collapses to 1px at the nearest edge")
  func outsideCollapses() {
    let band = PreviewAnchor.band(
      windowLeft: 0, windowWidth: 400, rowTop: 500, rowHeight: 44, visibleTop: 0,
      visibleHeight: 400)
    #expect(band.y == 399)
    #expect(band.height == 1)
  }

  @Test("Gap is positive")
  func gapPositive() {
    #expect(PreviewAnchor.gap > 0)
  }

  // T-PREVIEWWL1: mutter dismisses a non-grabbing popup that does not overlap
  // its parent's window geometry, so on Wayland the popup must reach back into
  // the window; X11 keeps the visible gap.
  @Test("Wayland: the popup's near edge lands inside the window, on both flip sides")
  func waylandPopupOverlapsWindow() {
    let windowWidth = 758
    let band = PreviewAnchor.band(
      windowLeft: 1, windowWidth: windowWidth - 2, rowTop: 0, rowHeight: 40, visibleTop: 0,
      visibleHeight: 400)
    let offset = Int(PreviewAnchor.offset(isWayland: true))
    let rightPlacementLeftEdge = band.x + band.width + offset
    let flippedPlacementRightEdge = band.x - offset
    #expect(rightPlacementLeftEdge < windowWidth)
    #expect(flippedPlacementRightEdge > 0)
  }

  @Test("X11 keeps the visible gap between the window and the preview")
  func x11KeepsGap() {
    #expect(PreviewAnchor.offset(isWayland: false) == PreviewAnchor.gap)
    #expect(PreviewAnchor.offset(isWayland: false) > 0)
  }
}
