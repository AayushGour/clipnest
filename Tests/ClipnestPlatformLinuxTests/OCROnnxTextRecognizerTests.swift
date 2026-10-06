// OCROnnxTextRecognizerTests.swift
//
// P8-B (Linux OCR: actually enable it): unit tests for
// `OnnxTextRecognizer`'s graceful-degradation contract — the whole point of
// moving to `dlopen`/`dlsym` (decision D66) is that `recognizeText` NEVER
// crashes or blocks, no matter which of the "OCR not usable yet" states is
// active (byte/pixel ceilings exceeded, `libonnxruntime.so.1` not
// installed, or the `clipnest-ocr` model files not installed) — matching
// `TextRecognizing`'s documented "returns nil on failure" contract exactly.
// These tests never depend on ONNX Runtime actually being present.
import ClipnestCore
import Foundation
import Testing

@testable import ClipnestLinuxOCR

/// A `MachineCapacityProbing` fake that always reports the same fixed
/// capacity — mirrors this module's own `MachineCapacityProbing` fakes in
/// `OCRTierSelectorTests.swift`, avoiding a dependency on real `/proc`
/// output for these tests.
private struct FixedMachineCapacityProber: MachineCapacityProbing {
  let capacity: MachineCapacity
  func probe() -> MachineCapacity { capacity }
}

@Suite("OnnxTextRecognizer")
struct OCROnnxTextRecognizerTests {

  private static let midRangeCapacity = MachineCapacity(
    physicalCores: 4, logicalCores: 8, availableRAMMB: 4096, hasAVX2: true, onBattery: false,
    cgroupCPUQuota: nil)

  @Test("should_return_nil_for_image_bytes_over_the_size_ceiling")
  func recognizeTextReturnsNilOverByteCeiling() async {
    let recognizer = OnnxTextRecognizer(
      modelLocator: StandardOCRModelLocator(fileExists: { _ in true }),
      capacityProber: FixedMachineCapacityProber(capacity: Self.midRangeCapacity))
    let oversizedData = Data(count: OnnxTextRecognizer.maxByteSize + 1)
    let result = await recognizer.recognizeText(in: oversizedData, quality: .fast)
    #expect(result == nil)
  }

  @Test("should_return_nil_when_no_model_files_are_installed")
  func recognizeTextReturnsNilWhenModelsMissing() async {
    // Simulates a machine with `clipnest-ocr` (models) NOT installed —
    // `OCRModelLocating.locate()` returning `nil` per its own documented
    // contract. `recognizeText` checks `OrtRuntimeAvailability.isAvailable`
    // BEFORE `modelLocator.locate()`, so on a machine without
    // `libonnxruntime.so.1` either (this suite's usual CI environment),
    // the earlier guard is what actually returns `nil` here — but the
    // observable contract this test asserts (`nil`, never a crash) holds
    // regardless of which guard fires first, which is what matters: a
    // missing model locator must never be masked by a crash further down.
    let recognizer = OnnxTextRecognizer(
      modelLocator: StandardOCRModelLocator(fileExists: { _ in false }),
      capacityProber: FixedMachineCapacityProber(capacity: Self.midRangeCapacity))
    let result = await recognizer.recognizeText(in: Data([0x01, 0x02, 0x03]), quality: .fast)
    #expect(result == nil)
  }

  @Test("should_return_nil_for_bytes_that_are_not_a_valid_PNG_header")
  func recognizeTextReturnsNilForInvalidPNGHeader() async {
    let recognizer = OnnxTextRecognizer(
      modelLocator: StandardOCRModelLocator(fileExists: { _ in true }),
      capacityProber: FixedMachineCapacityProber(capacity: Self.midRangeCapacity))
    let result = await recognizer.recognizeText(
      in: Data("not a png".utf8), quality: .accurate)
    #expect(result == nil)
  }

  @Test("should_never_crash_regardless_of_OrtRuntimeAvailability_on_this_machine")
  func recognizeTextNeverCrashesEitherWay() async {
    // `OrtRuntimeAvailability.isAvailable` reflects whatever is actually
    // installed on the machine running `swift test` (false on a bare CI
    // runner, true inside the packaging verification container) — this
    // test asserts the contract holds either way: a call with models
    // "installed" (fileExists always true) either degrades to `nil`
    // (ONNX Runtime not loadable) or attempts real recognition (loadable),
    // but never crashes or hangs either way.
    let recognizer = OnnxTextRecognizer(
      modelLocator: StandardOCRModelLocator(fileExists: { _ in true }),
      capacityProber: FixedMachineCapacityProber(capacity: Self.midRangeCapacity))
    _ = await recognizer.recognizeText(in: Data([0x01, 0x02, 0x03]), quality: .fast)
    #expect(Bool(true))
  }
}
