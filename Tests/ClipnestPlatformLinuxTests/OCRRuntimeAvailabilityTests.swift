// OCRRuntimeAvailabilityTests.swift
//
// P8-B (Linux OCR: actually enable it): `OrtRuntimeAvailability.isAvailable`
// used to be a compile-time `CLIPNEST_HAS_ONNXRUNTIME` fact; it is now a
// RUNTIME `dlopen` probe delegated straight to `OrtLibrary.isLoaded` (see
// decision D66 in `.claude/project-context.md`). This test asserts that
// delegation directly, rather than re-testing `OrtLibrary`'s own search
// logic (covered by `OCROrtLibraryTests.swift`).
import Testing

@testable import ClipnestLinuxOCR

@Suite("OrtRuntimeAvailability")
struct OCRRuntimeAvailabilityTests {

  @Test("should_mirror_OrtLibrary_isLoaded_exactly")
  func isAvailable_mirrorsOrtLibraryIsLoaded() {
    #expect(OrtRuntimeAvailability.isAvailable == OrtLibrary.isLoaded)
  }
}
