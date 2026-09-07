// OCRRealImageFixtureTests.swift
//
// T-OCR9/T-OCR10: end-to-end regression tests for both bugs this task
// fixed, using REAL image fixtures rendered at test time via ImageMagick's
// `convert -pointsize N label:"..."` (per this task's own verification
// brief) -- not synthetic tensors/geometry. The exact-algorithm regression
// pins for both bugs live in `Tests/ClipnestPlatformLinuxTests/
// OCRCharacterDictionaryTests.swift` (T-OCR9: `CTCDecoder`/
// `CharacterDictionary`, deterministic class-index arithmetic) and
// `OCRBoxOrderingTests.swift` (T-OCR10: exact geometry a single forward
// bubble pass under-sorts) -- those are the surgical, 100%-deterministic
// proofs that would fail without each fix. THIS file is the complementary
// full-pipeline proof: real PNG -> real PNG decode -> real DB detection ->
// real box ordering -> real crop -> real CTC recognition -> real character
// dictionary, run against the actual vendored ONNX Runtime + PP-OCRv5
// models, asserting the genuinely recognized string end to end.
//
// DELIBERATELY CONDITIONAL, not skipped/xfail -- mirrors
// `OCREndToEndRealModelTests`'s own "real model, graceful no-op outside a
// fully-provisioned container" shape exactly: on a bare `swift test` run
// with no `clipnest-ocr` installed and/or no `convert` on PATH (the
// ordinary case outside this task's own verification container), these
// tests only assert "no crash." Inside a container built from
// `packaging/linux/vnc/Dockerfile` (real vendored ONNX Runtime 1.28.1 +
// real PP-OCRv5 models installed, `imagemagick` already an apt dependency
// of that image), both branches run for real.
import ClipnestCore
import Foundation
import Testing

@testable import ClipnestLinuxOCR

@Suite("OCR real image fixtures (T-OCR9/T-OCR10)")
struct OCRRealImageFixtureTests {

  /// Locates `convert` on PATH without assuming a fixed install location
  /// (apt installs to `/usr/bin/convert` on Ubuntu, but this stays
  /// portable rather than hardcoding that). Returns `nil` — never
  /// crashes — if ImageMagick isn't installed, matching every other
  /// "ordinary state outside a fully-provisioned environment" check in
  /// this module (`OrtRuntimeAvailability.isAvailable`,
  /// `StandardOCRModelLocator.locate()`).
  private static func resolveConvertPath() -> String? {
    let candidates = ["/usr/bin/convert", "/usr/local/bin/convert"]
    if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
      return found
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "convert"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard
      let path = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !path.isEmpty
    else { return nil }
    return path
  }

  /// Renders `text` (may contain `\n` for multiple lines — ImageMagick's
  /// `label:` pseudo-format honors embedded newlines as line breaks) into
  /// a real PNG via `convert -size WxH -pointsize N -gravity center
  /// label:"..."`. `canvasSize` deliberately gives the text generous
  /// margin (a real screenshot/document is never cropped edge-to-edge to
  /// its text) — PP-OCRv5's detection model was trained on natural
  /// documents/screenshots, not text filling 100% of the frame; empirically
  /// (this task's own verification pass, see `logs/senior-dev.md`) a
  /// tightly-cropped label produced fragmented, incorrect detections that
  /// had nothing to do with either bug this file pins, while a padded
  /// canvas recognizes correctly and reliably. Returns `nil` on any
  /// failure (missing `convert`, non-zero exit, unreadable output) so
  /// callers can skip gracefully rather than fail outside a
  /// fully-provisioned environment.
  private static func renderLabelPNG(_ text: String, pointSize: Int, canvasSize: String)
    -> Data?
  {
    guard let convertPath = resolveConvertPath() else { return nil }
    let outputPath = NSTemporaryDirectory() + "clipnest-ocr-fixture-\(UUID().uuidString).png"
    defer { try? FileManager.default.removeItem(atPath: outputPath) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: convertPath)
    process.arguments = [
      "-size", canvasSize, "-background", "white", "-fill", "black", "-pointsize", "\(pointSize)",
      "-gravity", "center", "label:\(text)", outputPath,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
    } catch {
      return nil
    }
    return FileManager.default.contents(atPath: outputPath)
  }

  /// Both real-pipeline preconditions for a meaningful pass: `clipnest-ocr`
  /// (ONNX Runtime + PP-OCRv5 models) installed, AND `convert` on PATH.
  /// When either is false, this returns `nil` and every `@Test` below
  /// returns early — the ordinary, expected state outside this task's own
  /// verification container.
  private static func makeRecognizerIfFullyProvisioned() -> OnnxTextRecognizer? {
    guard OnnxTextRecognizer.isAvailable else { return nil }
    return OnnxTextRecognizer(modelLocator: StandardOCRModelLocator())
  }

  @Test(
    "T-OCR9 regression, real pipeline: multi-word text with spaces recognizes with spaces intact, not concatenated"
  )
  func multiWordTextKeepsSpacesEndToEnd() async throws {
    guard let recognizer = Self.makeRecognizerIfFullyProvisioned() else { return }
    guard
      let imageData = Self.renderLabelPNG("brown fox jumps", pointSize: 48, canvasSize: "800x200")
    else { return }

    let result = await recognizer.recognizeText(in: imageData, quality: .accurate)

    // Before the T-OCR9 fix, this decoded as "brownfoxjumps" — every space
    // silently dropped because the dictionary was one class short of
    // rec.onnx's real 18385 (see CharacterDictionary.appendingSpaceCharacter's
    // doc comment). Guard against both "recognized nothing" (an
    // environment problem, not what this test targets) and the specific
    // no-spaces regression before asserting the exact string, so a failure
    // message points at the right cause.
    let recognized = try #require(result, "expected real recognition, got nil — check environment")
    #expect(
      !recognized.contains("brownfox"),
      "spaces were dropped (T-OCR9 regression): got \"\(recognized)\"")
    #expect(recognized == "brown fox jumps")
  }

  @Test(
    "T-OCR10 regression, real pipeline: multi-line text recognizes in correct top-to-bottom reading order"
  )
  func multiLineTextRecognizesInReadingOrder() async throws {
    guard let recognizer = Self.makeRecognizerIfFullyProvisioned() else { return }
    // Two single-word lines (not multi-word-per-line) — deliberately
    // avoids a second, unrelated source of nondeterminism: whether real DB
    // detection merges within-line words into one box or several is not
    // what this test is pinning (that's BoxOrdering's own doc comment's
    // job, proven exactly and deterministically by the synthetic
    // `OCRBoxOrderingTests`). This test isolates the reading-ORDER
    // question alone: does the top line decode before the bottom line.
    guard let imageData = Self.renderLabelPNG("alpha\nomega", pointSize: 48, canvasSize: "500x300")
    else { return }

    let result = await recognizer.recognizeText(in: imageData, quality: .accurate)
    let recognized = try #require(result, "expected real recognition, got nil — check environment")
    #expect(recognized == "alpha\nomega")
  }
}
