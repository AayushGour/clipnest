// ScaledImageTests.swift
//
// T-PF3 (P0 image-hang fix), D4: `ScaledImage.displaySize(for:maxSide:)` was
// extracted out of `ScaledImage.body` so `ItemPreviewController
// .boundedImageContentSize` could size the preview popover with the exact
// same aspect-fit math the view itself renders with, without invoking a
// synchronous SwiftUI layout pass to discover it (see that method's doc
// comment). This suite pins down the pure math, independent of any SwiftUI
// rendering — no view is instantiated or laid out here.

import CoreGraphics
import Testing

// The `ClipnestApp` target's actual Swift module name is `Clipnest` (see
// `PRODUCT_NAME` in `project.yml`) — see `ItemKind+SFSymbolTests.swift`'s
// top doc comment for the full explanation.
@testable import Clipnest

@Suite("ScaledImage.displaySize")
struct ScaledImageDisplaySizeTests {

  @Test("A wide source is capped on width, height scaled to match its aspect ratio")
  func aspectFitsWideSource() {
    let result = ScaledImage.displaySize(for: CGSize(width: 400, height: 100), maxSide: 200)
    #expect(result.width == 200)
    #expect(result.height == 50)
  }

  @Test("A tall source is capped on height, width scaled to match its aspect ratio")
  func aspectFitsTallSource() {
    let result = ScaledImage.displaySize(for: CGSize(width: 100, height: 400), maxSide: 200)
    #expect(result.width == 50)
    #expect(result.height == 200)
  }

  @Test("A square source fits exactly into the maxSide × maxSide box")
  func squareSourceFitsExactly() {
    let result = ScaledImage.displaySize(for: CGSize(width: 300, height: 300), maxSide: 150)
    #expect(result.width == 150)
    #expect(result.height == 150)
  }

  @Test("A zero-size source falls back to a maxSide × maxSide box")
  func zeroSizeFallsBackToSquare() {
    let result = ScaledImage.displaySize(for: .zero, maxSide: 150)
    #expect(result.width == 150)
    #expect(result.height == 150)
  }

  @Test("A source already smaller than maxSide is scaled up to fill it, aspect preserved")
  func smallSourceScalesUpToFillMaxSide() {
    let result = ScaledImage.displaySize(for: CGSize(width: 50, height: 25), maxSide: 200)
    #expect(result.width == 200)
    #expect(result.height == 100)
  }
}
