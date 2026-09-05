import Foundation
import Testing

@testable import ClipnestCore

/// P2-E (Linux port): unit tests for `UnavailableImagePixelHasher` — the
/// non-Apple default `ImagePixelHashing` conformance. Asserts the one
/// contract that matters (see that type's doc comment): it ALWAYS returns
/// `nil`, for any input, including real decodable image bytes — never a
/// weaker/lossy hash, since `PasteboardReader.imageContentHash(for:
/// dimensions:)`'s existing `nil`-hasher fallback to the exact raw-byte
/// hash is what makes `nil` safe here (see D44 in project-context.md).
@Suite("UnavailableImagePixelHasher")
struct UnavailableImagePixelHasherTests {
  private let hasher = UnavailableImagePixelHasher()

  @Test("Returns nil for a real, well-formed, decodable PNG")
  func returnsNilForDecodablePNG() {
    let imageData = ImageFixtures.makeTinyImageData(width: 10, height: 10, format: .png)

    #expect(hasher.pixelContentHash(of: imageData) == nil)
  }

  @Test("Returns nil for a real, well-formed, decodable TIFF")
  func returnsNilForDecodableTIFF() {
    let imageData = ImageFixtures.makeTinyImageData(width: 10, height: 10, format: .tiff)

    #expect(hasher.pixelContentHash(of: imageData) == nil)
  }

  @Test("Returns nil for empty data")
  func returnsNilForEmptyData() {
    #expect(hasher.pixelContentHash(of: Data()) == nil)
  }

  @Test("Returns nil for arbitrary undecodable bytes")
  func returnsNilForUndecodableBytes() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])

    #expect(hasher.pixelContentHash(of: garbage) == nil)
  }
}
