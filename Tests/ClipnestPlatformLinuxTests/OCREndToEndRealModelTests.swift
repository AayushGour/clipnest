// OCREndToEndRealModelTests.swift
//
// P8-B (Linux OCR: actually enable it): the ONE test in this module that
// exercises the ENTIRE real pipeline -- dlopen/dlsym-resolved ONNX
// Runtime (OrtLibrary), a real PP-OCRv5 mobile detection + recognition
// model pair, PNG decode, DB post-process, box unclip/scaling/ordering,
// text-line cropping, CTC decode -- against a real rendered image, asserting
// the ACTUAL recognized string. Every other OCR*Tests.swift file in this
// module tests one piece in isolation with synthetic data; this one is the
// integration proof.
//
// DELIBERATELY CONDITIONAL, not skipped/xfail: on a bare CI runner (no
// clipnest-ocr installed -- the ordinary case for `swift test` outside a
// fully-provisioned packaging/verification container), OrtRuntimeAvailability
// .isAvailable is false and this test only asserts "no crash," matching
// every other conditional real-library test in OCROrtLibraryTests.swift.
// Inside this task's own Docker verification container -- real, vendored
// ONNX Runtime 1.28.1 (packaging/linux/vendor/onnxruntime) installed at
// /usr/lib/clipnest/libonnxruntime.so.1, plus real PP-OCRv5 mobile
// det/rec/cls ONNX models (sourced from RapidOCR's ModelScope-hosted
// conversion -- see OrtSession.swift's runDetection/runRecognition
// doc comments for exact provenance) at /usr/share/clipnest-ocr/models/
// -- this test's real branch runs and asserts genuine, correct recognition:
// see .claude/logs/senior-dev.md (P8-B) for the full transcript,
// including the real bugs this exact test surfaced and this task fixed
// (OrtEnvironment.withSessions's self-deadlock, ImagePreprocessing's
// wrong ImageNet-vs-PP-OCR normalization constants, and
// PolygonUnclip.expand's centroid-radial-push under-expanding height on
// wide text-line boxes) before it passed.
import ClipnestCore
import Foundation
import Testing

@testable import ClipnestLinuxOCR

@Suite("OCR end-to-end (real model)")
struct OCREndToEndRealModelTests {

  /// A real PNG (400x100, white background, "Hello Clipnest" rendered in
  /// 36pt DejaVu Sans Bold) -- embedded as base64 rather than a bundled
  /// resource file so this test target needs no Package.swift resources
  /// declaration. Small enough (roughly 3.4KB decoded) to embed directly.
  private static let renderedTextImageBase64 = """
    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
    """

  @Test("should_recognize_the_actual_rendered_text_when_a_real_model_is_installed")
  func recognizesRealRenderedText() async throws {
    let imageData = try #require(Data(base64Encoded: Self.renderedTextImageBase64))

    let modelsInstalled = StandardOCRModelLocator().locate() != nil
    guard OrtRuntimeAvailability.isAvailable, modelsInstalled else {
      // Ordinary state outside a fully-provisioned verification container
      // (see this file's own top comment) -- clipnest never requires
      // clipnest-ocr to be installed, so this is not a failure.
      return
    }

    let recognizer = OnnxTextRecognizer(modelLocator: StandardOCRModelLocator())
    let result = await recognizer.recognizeText(in: imageData, quality: .accurate)
    #expect(result == "Hello\nClipnest")
  }
}
