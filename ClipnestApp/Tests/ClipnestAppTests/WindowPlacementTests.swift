// WindowPlacementTests.swift
//
// `WindowPlacement` is pure `CGRect`/`CGPoint`/`CGSize` geometry math with
// zero AppKit dependency (see that file's own top doc comment) — flagged by
// the implementation review as testable today with no fakes/mocks needed.
// Every expected value below is hand-computed straight from
// `WindowPlacement.swift`'s own formulas, not just re-asserting whatever the
// implementation happens to currently return.

import CoreGraphics
import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import Clipnest

@Suite("WindowPlacement")
struct WindowPlacementTests {

  // MARK: - clampedOrigin

  @Test("An origin already fully inside the bounds is returned unchanged")
  func clampedOriginInsideBoundsUnchanged() {
    let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let size = CGSize(width: 400, height: 300)
    let origin = CGPoint(x: 500, y: 500)

    let result = WindowPlacement.clampedOrigin(origin, size: size, in: bounds)

    #expect(result == origin)
  }

  @Test("An origin past the bottom-left (negative) edge clamps up to bounds.minX/minY")
  func clampedOriginBelowLeftEdgeClampsToMin() {
    let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let size = CGSize(width: 400, height: 300)
    let origin = CGPoint(x: -500, y: -200)

    let result = WindowPlacement.clampedOrigin(origin, size: size, in: bounds)

    #expect(result == CGPoint(x: 0, y: 0))
  }

  @Test("An origin past the top-right edge clamps so the frame's far edge aligns with the bounds")
  func clampedOriginAboveRightEdgeClampsToMax() {
    let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let size = CGSize(width: 400, height: 300)
    let origin = CGPoint(x: 3000, y: 2000)

    let result = WindowPlacement.clampedOrigin(origin, size: size, in: bounds)

    // maxX = bounds.maxX(1920) - size.width(400) = 1520; maxY = 1080 - 300 = 780.
    #expect(result == CGPoint(x: 1520, y: 780))
  }

  @Test(
    "Clamps correctly against a secondary screen's negative-coordinate bounds (multi-monitor)"
  )
  func clampedOriginNegativeCoordinateBoundsMultiScreen() {
    // A secondary screen positioned to the left of the primary (AppKit
    // screen coordinates: x runs from -1920 to 0 for a 1920pt-wide screen
    // sitting immediately left of a primary screen starting at x = 0).
    let bounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let size = CGSize(width: 300, height: 200)
    // Would place the window's right edge at -100 + 300 = 200, off the
    // secondary screen's right edge (bounds.maxX == 0).
    let origin = CGPoint(x: -100, y: 50)

    let result = WindowPlacement.clampedOrigin(origin, size: size, in: bounds)

    // maxX = bounds.maxX(0) - size.width(300) = -300; y is already in bounds (50 < maxY 880).
    #expect(result == CGPoint(x: -300, y: 50))
  }

  @Test("A window larger than the bounds in both dimensions clamps to bounds.minX/minY")
  func clampedOriginSizeLargerThanBoundsClampsToMin() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
    let size = CGSize(width: 400, height: 300)
    let origin = CGPoint(x: 50, y: 50)

    let result = WindowPlacement.clampedOrigin(origin, size: size, in: bounds)

    // maxX = max(bounds.maxX(200) - size.width(400), bounds.minX(0)) = 0; same for Y.
    #expect(result == CGPoint(x: 0, y: 0))
  }

  // MARK: - pairLayout

  @Test(
    "When the pair fits and the picker already has room, the picker is left unmoved and the editor is placed to its right, top-aligned"
  )
  func pairLayoutFitsPickerAlreadyHasRoomStaysPut() {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let pickerFrame = CGRect(x: 100, y: 200, width: 400, height: 500)
    let editorSize = CGSize(width: 350, height: 450)
    let gap: CGFloat = 12

    let result = WindowPlacement.pairLayout(
      pickerFrame: pickerFrame, editorSize: editorSize, screenVisibleFrame: screen, gap: gap)

    #expect(result.pickerOrigin == CGPoint(x: 100, y: 200))
    #expect(result.editorOrigin == CGPoint(x: 512, y: 250))
    // Top-aligned: both windows' maxY match.
    #expect(result.pickerOrigin.y + pickerFrame.height == result.editorOrigin.y + editorSize.height)
    // Zero overlap: editor's left edge is at/after the picker's right edge.
    #expect(result.editorOrigin.x >= result.pickerOrigin.x + pickerFrame.width)
  }

  @Test(
    "When the pair fits but the picker's current position leaves no room, the picker is shifted left (never right) just enough"
  )
  func pairLayoutFitsShiftsPickerLeftWhenNeeded() {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    // Near the right edge — no room for a 300pt-wide editor + 10pt gap here.
    let pickerFrame = CGRect(x: 1600, y: 100, width: 400, height: 500)
    let editorSize = CGSize(width: 300, height: 400)
    let gap: CGFloat = 10

    let result = WindowPlacement.pairLayout(
      pickerFrame: pickerFrame, editorSize: editorSize, screenVisibleFrame: screen, gap: gap)

    #expect(result.pickerOrigin == CGPoint(x: 1210, y: 100))
    #expect(result.editorOrigin == CGPoint(x: 1620, y: 200))
    #expect(result.pickerOrigin.x < pickerFrame.minX)  // moved left, never right
    #expect(
      result.editorOrigin.x == result.pickerOrigin.x + pickerFrame.width + gap)
  }

  @Test(
    "When the pair can't fit the screen's width at full size, the picker is clamped as-is and the editor is pushed flush against the screen's right edge"
  )
  func pairLayoutDoesNotFitPushesEditorFlushRight() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let pickerFrame = CGRect(x: 50, y: 100, width: 900, height: 600)
    let editorSize = CGSize(width: 300, height: 400)
    let gap: CGFloat = 20

    let result = WindowPlacement.pairLayout(
      pickerFrame: pickerFrame, editorSize: editorSize, screenVisibleFrame: screen, gap: gap)

    #expect(result.pickerOrigin == CGPoint(x: 50, y: 100))
    #expect(result.editorOrigin == CGPoint(x: 700, y: 300))
    // Flush against the screen's right edge.
    #expect(result.editorOrigin.x + editorSize.width == screen.maxX)
  }

  @Test(
    "In the pathological narrow-screen case that forces the last-resort nudge, both origins stay on screen with distinct left edges"
  )
  func pairLayoutPathologicalCaseNudgesToDistinctLeftEdges() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let pickerFrame = CGRect(x: 750, y: 50, width: 200, height: 300)
    // Wide enough, relative to the picker's position, that pushing the
    // editor flush right (screen.maxX - editorSize.width = 200) would land
    // it AT/left of the picker's own left edge (750) before the 1pt nudge.
    let editorSize = CGSize(width: 800, height: 250)
    let gap: CGFloat = 10

    let result = WindowPlacement.pairLayout(
      pickerFrame: pickerFrame, editorSize: editorSize, screenVisibleFrame: screen, gap: gap)

    // Both frames still fully on screen (guaranteed by the final
    // `clampedOrigin` pass on each).
    #expect(screen.contains(CGRect(origin: result.pickerOrigin, size: pickerFrame.size)))
    #expect(screen.contains(CGRect(origin: result.editorOrigin, size: editorSize)))
    // Distinct left edges — the guarantee this pathological case exists to test.
    #expect(result.pickerOrigin.x != result.editorOrigin.x)
    #expect(result.pickerOrigin == CGPoint(x: 750, y: 50))
    #expect(result.editorOrigin == CGPoint(x: 200, y: 100))
  }

  // MARK: - Item-preview side

  /// A 1440-wide screen with the picker (560 wide) sitting left of centre, so
  /// there is clearly more room on its right.
  private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  private static let pickerLeftOfCentre = CGRect(x: 300, y: 200, width: 560, height: 420)
  private static let gap: CGFloat = 24

  @Test("preview side: more room right -> right")
  func previewSidePrefersRoomierRight() {
    #expect(
      WindowPlacement.previewSide(
        anchorRect: Self.pickerLeftOfCentre, screenVisibleFrame: Self.screen, gap: Self.gap)
        == .right)
  }

  @Test("preview side: more room left -> left")
  func previewSidePrefersRoomierLeft() {
    // Picker pushed to the right edge: 1440 - (1000 + 560) leaves nothing right.
    let picker = CGRect(x: 860, y: 200, width: 560, height: 420)
    #expect(
      WindowPlacement.previewSide(
        anchorRect: picker, screenVisibleFrame: Self.screen, gap: Self.gap) == .left)
  }

  /// The actual reported bug: the preview panel's width varies per item, and
  /// the old rule ("right if the panel fits, else left") therefore flipped
  /// sides from row to row. The side must not depend on panel width at all.
  @Test("preview side is identical regardless of how wide that item's panel is")
  func previewSideIsIndependentOfPanelWidth() {
    let side = WindowPlacement.previewSide(
      anchorRect: Self.pickerLeftOfCentre, screenVisibleFrame: Self.screen, gap: Self.gap)

    // A narrow text preview and a huge image preview must land on the SAME
    // side — only their origin differs, never which side of the picker.
    for panelWidth in [200.0, 400.0, 560.0, 900.0] as [CGFloat] {
      let originX = WindowPlacement.previewOriginX(
        on: side,
        anchorRect: Self.pickerLeftOfCentre,
        panelWidth: panelWidth,
        screenVisibleFrame: Self.screen,
        gap: Self.gap)
      // `side` is .right here, so every one of them sits at or right of the
      // picker's trailing edge — never flipped to the left of it.
      #expect(originX >= Self.pickerLeftOfCentre.maxX - panelWidth)
      #expect(originX + panelWidth <= Self.screen.maxX)
    }
  }

  @Test("preview origin: right side sits one gap past the picker")
  func previewOriginRight() {
    let originX = WindowPlacement.previewOriginX(
      on: .right,
      anchorRect: Self.pickerLeftOfCentre,
      panelWidth: 300,
      screenVisibleFrame: Self.screen,
      gap: Self.gap)
    #expect(originX == Self.pickerLeftOfCentre.maxX + Self.gap)  // 860 + 24
  }

  @Test("preview origin: left side ends one gap before the picker")
  func previewOriginLeft() {
    let picker = CGRect(x: 860, y: 200, width: 560, height: 420)
    let originX = WindowPlacement.previewOriginX(
      on: .left,
      anchorRect: picker,
      panelWidth: 300,
      screenVisibleFrame: Self.screen,
      gap: Self.gap)
    #expect(originX == picker.minX - Self.gap - 300)  // 860 - 24 - 300
  }

  /// Staying fully on screen beats honoring the gap — an unreadable
  /// half-off-screen preview is worse than one that overlaps the picker.
  @Test("preview origin stays on screen when the panel is wider than its side")
  func previewOriginClampsOnScreen() {
    let rightX = WindowPlacement.previewOriginX(
      on: .right,
      anchorRect: Self.pickerLeftOfCentre,
      panelWidth: 1200,
      screenVisibleFrame: Self.screen,
      gap: Self.gap)
    #expect(rightX + 1200 <= Self.screen.maxX)

    let picker = CGRect(x: 100, y: 200, width: 560, height: 420)
    let leftX = WindowPlacement.previewOriginX(
      on: .left,
      anchorRect: picker,
      panelWidth: 400,
      screenVisibleFrame: Self.screen,
      gap: Self.gap)
    #expect(leftX >= Self.screen.minX)
  }

  @Test("available width matches the room on the chosen side")
  func previewAvailableWidthMatchesSide() {
    // screen.maxX 1440 - picker.maxX 860 - gap 24
    let expectedRight: CGFloat = 556
    // picker.minX 300 - screen.minX 0 - gap 24
    let expectedLeft: CGFloat = 276

    let right = WindowPlacement.previewAvailableWidth(
      on: .right, anchorRect: Self.pickerLeftOfCentre,
      screenVisibleFrame: Self.screen, gap: Self.gap)
    let left = WindowPlacement.previewAvailableWidth(
      on: .left, anchorRect: Self.pickerLeftOfCentre,
      screenVisibleFrame: Self.screen, gap: Self.gap)

    #expect(right == expectedRight)
    #expect(left == expectedLeft)
  }
}
