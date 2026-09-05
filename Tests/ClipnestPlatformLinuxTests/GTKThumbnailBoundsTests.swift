// GTKThumbnailBoundsTests.swift
//
// P7-D (Linux port, GTK4 view layer): pins the exact fix this task warned
// not to regress (project-context.md D42-D45 — the macOS P0 hang from
// decoding a full-resolution image to draw a tiny icon). See
// GTKKeyEventMappingTests.swift's top doc comment for the
// `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency note
// that applies to every `GTK*Tests.swift` file.
import Testing

@testable import ClipnestGTK

@Suite("ThumbnailBounds")
struct GTKThumbnailBoundsTests {
  @Test("A source smaller than the ceiling is left at its own size — never upscaled")
  func smallSourceUnchanged() {
    let size = ThumbnailBounds.boundedSize(originalWidth: 32, originalHeight: 16, maxPixelSize: 64)
    #expect(size.width == 32)
    #expect(size.height == 16)
  }

  @Test("A source exactly at the ceiling is left unchanged")
  func exactCeilingUnchanged() {
    let size = ThumbnailBounds.boundedSize(originalWidth: 64, originalHeight: 64, maxPixelSize: 64)
    #expect(size.width == 64)
    #expect(size.height == 64)
  }

  @Test("A landscape source over the ceiling is downscaled preserving aspect ratio")
  func landscapeOverCeilingDownscaled() {
    // 25,000,000-byte-class screenshot stand-in: 5000x2500, way over any
    // sane row/preview ceiling.
    let size = ThumbnailBounds.boundedSize(
      originalWidth: 5000, originalHeight: 2500, maxPixelSize: 512)
    #expect(size.width == 512)
    #expect(size.height == 256)
  }

  @Test("A portrait source over the ceiling bounds the TALLER edge, not width")
  func portraitOverCeilingBoundsHeight() {
    let size = ThumbnailBounds.boundedSize(
      originalWidth: 1000, originalHeight: 4000, maxPixelSize: 400)
    #expect(size.height == 400)
    #expect(size.width == 100)
  }

  @Test("Degenerate (non-positive) source dimensions fall back to a safe 1x1")
  func degenerateSourceFallsBackToOnePixel() {
    #expect(
      ThumbnailBounds.boundedSize(originalWidth: 0, originalHeight: 100, maxPixelSize: 64) == (1, 1)
    )
    #expect(
      ThumbnailBounds.boundedSize(originalWidth: 100, originalHeight: -5, maxPixelSize: 64) == (
        1, 1
      ))
  }

  @Test("The row icon ceiling is meaningfully smaller than the preview ceiling")
  func rowCeilingSmallerThanPreviewCeiling() {
    #expect(ThumbnailBounds.rowIconMaxPixelSize < ThumbnailBounds.previewMaxPixelSize)
  }
}
