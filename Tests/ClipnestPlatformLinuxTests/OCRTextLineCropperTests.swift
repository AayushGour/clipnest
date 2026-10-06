// OCRTextLineCropperTests.swift
//
// P6-C (Linux OCR): unit tests for `TextLineCropper` — bounding-box
// computation, pixel cropping, and bilinear resize, all pure buffer math
// with no ONNX Runtime dependency.
import Testing

@testable import ClipnestLinuxOCR

@Suite("TextLineCropper")
struct OCRTextLineCropperTests {

  private static func solidBuffer(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8))
    -> RGBAImageBuffer
  {
    var pixels: [UInt8] = []
    pixels.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) {
      pixels.append(contentsOf: [color.0, color.1, color.2, color.3])
    }
    // Force-try is acceptable here: test-only setup with a guaranteed-valid
    // pixel count.
    return RGBAImageBuffer(width: width, height: height, pixels: pixels)!
  }

  @Test("boundingBox computes the axis-aligned box of a quad and clamps to image bounds")
  func boundingBoxComputesAndClamps() {
    let quad = Quadrilateral(
      topLeft: Point2D(x: 2, y: 3), topRight: Point2D(x: 8, y: 3),
      bottomRight: Point2D(x: 8, y: 9), bottomLeft: Point2D(x: 2, y: 9))
    let box = TextLineCropper.boundingBox(of: quad, imageWidth: 100, imageHeight: 100)
    #expect(box.x == 2)
    #expect(box.y == 3)
    #expect(box.width == 6)
    #expect(box.height == 6)

    // A quad partly outside the image (as an unclip expansion can produce)
    // must clamp, not go negative or exceed image bounds.
    let overflowing = Quadrilateral(
      topLeft: Point2D(x: -5, y: -5), topRight: Point2D(x: 12, y: -5),
      bottomRight: Point2D(x: 12, y: 12), bottomLeft: Point2D(x: -5, y: 12))
    let clamped = TextLineCropper.boundingBox(of: overflowing, imageWidth: 10, imageHeight: 10)
    #expect(clamped.x == 0)
    #expect(clamped.y == 0)
    #expect(clamped.width == 10)
    #expect(clamped.height == 10)
  }

  @Test("crop extracts exactly the requested sub-region's pixels")
  func cropExtractsCorrectSubRegion() {
    // 4x4 image where pixel (x,y) is (x*10, y*10, 0, 255) — a distinct,
    // checkable value per pixel.
    var pixels: [UInt8] = []
    for y in 0..<4 {
      for x in 0..<4 {
        pixels.append(contentsOf: [UInt8(x * 10), UInt8(y * 10), 0, 255])
      }
    }
    let image = RGBAImageBuffer(width: 4, height: 4, pixels: pixels)!

    let cropped = TextLineCropper.crop(image, boundingBox: (x: 1, y: 1, width: 2, height: 2))
    #expect(cropped?.width == 2)
    #expect(cropped?.height == 2)
    // Top-left of the crop is original (1,1) -> (10, 10, 0, 255).
    #expect(cropped?.pixels[0...3] == [10, 10, 0, 255])
    // Bottom-right of the crop is original (2,2) -> (20, 20, 0, 255).
    #expect(cropped?.pixels[12...15] == [20, 20, 0, 255])
  }

  @Test("crop returns nil for a zero-area or out-of-bounds box")
  func cropRejectsDegenerateBoxes() {
    let image = Self.solidBuffer(width: 4, height: 4, color: (1, 2, 3, 255))
    #expect(TextLineCropper.crop(image, boundingBox: (x: 0, y: 0, width: 0, height: 2)) == nil)
    #expect(TextLineCropper.crop(image, boundingBox: (x: 3, y: 0, width: 2, height: 2)) == nil)
    #expect(TextLineCropper.crop(image, boundingBox: (x: -1, y: 0, width: 2, height: 2)) == nil)
  }

  @Test("resizedToRecognitionHeight scales to exactly 48px height, preserving aspect ratio")
  func resizeToRecognitionHeightScalesCorrectly() {
    let image = Self.solidBuffer(width: 100, height: 25, color: (5, 6, 7, 255))
    let resized = TextLineCropper.resizedToRecognitionHeight(image)
    #expect(resized.height == TextLineCropper.recognitionInputHeight)
    #expect(resized.width == 192)  // 100 * (48/25) = 192
  }

  @Test("resizing a solid-color image keeps every pixel the same color")
  func resizeOfSolidColorStaysUniform() {
    let image = Self.solidBuffer(width: 10, height: 10, color: (42, 84, 126, 255))
    let resized = TextLineCropper.resized(image, targetWidth: 25, targetHeight: 13)
    #expect(resized.width == 25)
    #expect(resized.height == 13)
    for pixelIndex in 0..<(resized.width * resized.height) {
      let offset = pixelIndex * RGBAImageBuffer.bytesPerPixel
      #expect(resized.pixels[offset] == 42)
      #expect(resized.pixels[offset + 1] == 84)
      #expect(resized.pixels[offset + 2] == 126)
      #expect(resized.pixels[offset + 3] == 255)
    }
  }

  @Test("resize of a degenerate (zero-size) image returns it unchanged, never crashes")
  func resizeHandlesDegenerateInputSafely() {
    let empty = RGBAImageBuffer(width: 0, height: 0, pixels: [])!
    let resized = TextLineCropper.resized(empty, targetWidth: 10, targetHeight: 10)
    #expect(resized.width == 0)
    #expect(resized.height == 0)
  }
}
