// OrtSession.swift
//
// P6-C / P8-B (Linux OCR): the actual ONNX Runtime C API calls — creating
// the shared `OrtEnv`, per-model `OrtSession`s, and running inference.
//
// VERIFIED AGAINST THE REAL HEADER as of P8-B: `Sources/COnnxRuntime/shim.h`
// now declares `OrtApi`/`OrtApiBase` mechanically derived from the real,
// vendored `onnxruntime_c_api.h` (ONNX Runtime 1.28.1 — see that file's own
// top comment for the full derivation + verification methodology), and
// `OrtGetApiBase` is resolved via `dlopen`/`dlsym` (`OrtLibrary.swift`)
// rather than a link-time call — see decision D66 in
// `.claude/project-context.md`. This module still uses ONLY the C API,
// never the C++ headers (the C++ API wraps this same C struct and would
// drag a libstdc++ ABI dependency across the Swift boundary that the C API
// does not have).
//
// This file is compiled UNCONDITIONALLY on Linux now — `import
// COnnxRuntime` can never fail to resolve (see `shim.h`'s top comment) —
// but every ORT call it makes is only ever reached once
// `OrtRuntimeAvailability.isAvailable` (a RUNTIME `dlopen` check, not a
// compile-time one) is true; see that type's doc comment.
import COnnxRuntime
import Foundation

/// A loaded det/rec(/cls) session triple, plus the `OrtApi` table and
/// shared memory-info handle every `Run` call needs. One instance is
/// cached by `OrtEnvironment` and reused across recognitions until either
/// the tier/model paths change or the 60s idle timer releases it.
final class OrtSessionSet {
  let modelPaths: OCRModelPaths
  let intraOpNumThreads: Int
  let hasOrientationSession: Bool

  private let api: UnsafePointer<OrtApi>
  private let environment: OpaquePointer  // OrtEnv*
  private let memoryInfo: OpaquePointer  // OrtMemoryInfo*
  private let detectionSession: OpaquePointer  // OrtSession*
  private let recognitionSession: OpaquePointer  // OrtSession*
  private let orientationSession: OpaquePointer?  // OrtSession*, nil if tier skips it

  private init(
    modelPaths: OCRModelPaths, intraOpNumThreads: Int, hasOrientationSession: Bool,
    api: UnsafePointer<OrtApi>, environment: OpaquePointer, memoryInfo: OpaquePointer,
    detectionSession: OpaquePointer, recognitionSession: OpaquePointer,
    orientationSession: OpaquePointer?
  ) {
    self.modelPaths = modelPaths
    self.intraOpNumThreads = intraOpNumThreads
    self.hasOrientationSession = hasOrientationSession
    self.api = api
    self.environment = environment
    self.memoryInfo = memoryInfo
    self.detectionSession = detectionSession
    self.recognitionSession = recognitionSession
    self.orientationSession = orientationSession
  }

  deinit {
    if let orientationSession { api.pointee.ReleaseSession(orientationSession) }
    api.pointee.ReleaseSession(recognitionSession)
    api.pointee.ReleaseSession(detectionSession)
    api.pointee.ReleaseMemoryInfo(memoryInfo)
    // NOTE: `environment` (the shared `OrtEnv`) is intentionally NOT
    // released here — `OrtEnvironment` owns its lifetime, not this
    // per-tier session set (see `OrtEnvironment.ortEnvironmentOrCreate`).
  }

  /// The ONNX Runtime API version this module is compiled and vendored
  /// against — VERIFIED (not assumed) against the real, vendored
  /// `onnxruntime_c_api.h`'s own `#define ORT_API_VERSION` for ONNX
  /// Runtime 1.28.1 (see `packaging/linux/vendor/onnxruntime/VERSION` and
  /// `shim.h`'s top comment). Previously assumed `21` in this module's
  /// earlier "written directly from the C API's well-documented shape,
  /// unverified against real headers" pass — corrected once the real
  /// header became available to check against. `ORT_API_VERSION` itself
  /// (from `shim.h`) is what's actually passed to `GetApi` below; this
  /// constant only documents intent, per coding-standards.md's
  /// no-magic-numbers rule.
  static let targetApiVersion: UInt32 = 28

  /// `OrtGetApiBase()->GetApi(...)` can legitimately return `NULL` if the
  /// loaded `libonnxruntime.so.1`'s ABI version is older than
  /// `ORT_API_VERSION` — handled as an ordinary failure (`nil`), not a
  /// crash, exactly like every other fallible step in this pipeline.
  /// `OrtGetApiBase` itself is resolved via `OrtLibrary.apiBase()`
  /// (`dlopen`/`dlsym`, never a linked call) rather than called directly —
  /// see `OrtLibrary.swift`'s doc comment for why.
  private static func loadApi() -> UnsafePointer<OrtApi>? {
    guard let base = OrtLibrary.apiBase() else { return nil }
    guard let getApi = base.pointee.GetApi else { return nil }
    guard let apiPointer = getApi(targetApiVersion) else { return nil }
    return apiPointer
  }

  /// Creates the ONE shared `OrtEnv` for the process. Logging is set to
  /// `ORT_LOGGING_LEVEL_WARNING` — ORT's own internal logs are
  /// diagnostic/metadata (model load errors, etc.), never clipboard
  /// content, so this doesn't need this module's metadata-only logging
  /// discipline to route through it; ORT's default log sink (stderr) is
  /// acceptable for a background CLI-launched process.
  static func createEnvironment() -> OpaquePointer? {
    guard let api = loadApi() else { return nil }
    var env: OpaquePointer?
    let status = "clipnest-ocr".withCString { logId in
      api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, logId, &env)
    }
    guard OrtStatusChecking.succeeded(status, api: api) else { return nil }
    return env
  }

  /// Builds session options for one model at the given tier's thread
  /// count, with spin-waiting disabled (mandatory per this task's plan:
  /// ORT's default intra-op thread pool spins before blocking, burning a
  /// full core per thread while idle — unacceptable for a background
  /// clipboard manager on a laptop) — then creates the session from
  /// `modelPath`.
  private static func createSession(
    api: UnsafePointer<OrtApi>, environment: OpaquePointer, modelPath: String,
    intraOpNumThreads: Int
  ) -> OpaquePointer? {
    var options: OpaquePointer?
    guard OrtStatusChecking.succeeded(api.pointee.CreateSessionOptions(&options), api: api),
      let options
    else { return nil }
    defer { api.pointee.ReleaseSessionOptions(options) }

    guard
      OrtStatusChecking.succeeded(
        api.pointee.SetIntraOpNumThreads(options, Int32(intraOpNumThreads)), api: api)
    else { return nil }

    // Mandatory per this function's doc comment.
    let configStatus = "session.intra_op.allow_spinning".withCString { key in
      "0".withCString { value in
        api.pointee.AddSessionConfigEntry(options, key, value)
      }
    }
    guard OrtStatusChecking.succeeded(configStatus, api: api) else { return nil }

    var session: OpaquePointer?
    let status = modelPath.withCString { modelPathCString in
      api.pointee.CreateSession(environment, modelPathCString, options, &session)
    }
    guard OrtStatusChecking.succeeded(status, api: api) else { return nil }
    return session
  }

  /// Builds a fresh det/rec(/cls) session triple for `modelPaths` at
  /// `tier`'s settings. `environment` is the shared `OrtEnv` — NOT
  /// released by this instance (see `deinit`'s note).
  static func create(
    environment: OpaquePointer, modelPaths: OCRModelPaths, tier: OCRTierConfiguration
  )
    -> OrtSessionSet?
  {
    guard let api = loadApi() else { return nil }

    var memoryInfo: OpaquePointer?
    let memoryStatus = api.pointee.CreateCpuMemoryInfo(
      OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo)
    guard OrtStatusChecking.succeeded(memoryStatus, api: api), let memoryInfo else { return nil }

    guard
      let detectionSession = createSession(
        api: api, environment: environment, modelPath: modelPaths.detectionModelPath,
        intraOpNumThreads: tier.intraOpNumThreads)
    else {
      api.pointee.ReleaseMemoryInfo(memoryInfo)
      return nil
    }
    guard
      let recognitionSession = createSession(
        api: api, environment: environment, modelPath: modelPaths.recognitionModelPath,
        intraOpNumThreads: tier.intraOpNumThreads)
    else {
      api.pointee.ReleaseSession(detectionSession)
      api.pointee.ReleaseMemoryInfo(memoryInfo)
      return nil
    }

    var orientationSession: OpaquePointer?
    if tier.runsOrientationClassifier {
      orientationSession = createSession(
        api: api, environment: environment, modelPath: modelPaths.orientationModelPath,
        intraOpNumThreads: tier.intraOpNumThreads)
      guard orientationSession != nil else {
        api.pointee.ReleaseSession(recognitionSession)
        api.pointee.ReleaseSession(detectionSession)
        api.pointee.ReleaseMemoryInfo(memoryInfo)
        return nil
      }
    }

    return OrtSessionSet(
      modelPaths: modelPaths, intraOpNumThreads: tier.intraOpNumThreads,
      hasOrientationSession: tier.runsOrientationClassifier, api: api, environment: environment,
      memoryInfo: memoryInfo, detectionSession: detectionSession,
      recognitionSession: recognitionSession, orientationSession: orientationSession)
  }

  /// Runs one model on one NCHW `Float` input tensor and returns its
  /// first output tensor's data as `[Float]`, plus that output's shape.
  /// `inputName`/`outputName` are the exported ONNX graph's tensor names —
  /// VERIFIED as of P8-B for the specific PP-OCRv5 export this module
  /// recommends (see each of the three call sites below — `runDetection`/
  /// `runRecognition`/`runOrientationClassifier` — for the exact verified
  /// name and source). Kept as parameters (not hardcoded deep inside)
  /// specifically so reconciling against a DIFFERENT export is a one-line
  /// call-site change, not a rewrite of this function.
  private func run(
    session: OpaquePointer, inputName: String, outputName: String, inputData: [Float],
    inputShape: [Int64]
  ) -> (data: [Float], shape: [Int64])? {
    dispatchPrecondition(condition: .onQueue(OrtEnvironment.shared.queue))

    var createdInputTensor: OpaquePointer?
    let tensorStatus = inputData.withUnsafeBufferPointer { buffer -> OrtStatusPtr? in
      inputShape.withUnsafeBufferPointer { shapeBuffer in
        withUnsafeMutablePointer(to: &createdInputTensor) { out in
          api.pointee.CreateTensorWithDataAsOrtValue(
            memoryInfo, UnsafeMutableRawPointer(mutating: buffer.baseAddress),
            buffer.count * MemoryLayout<Float>.stride, shapeBuffer.baseAddress, shapeBuffer.count,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, out)
        }
      }
    }
    guard OrtStatusChecking.succeeded(tensorStatus, api: api),
      let inputTensor = createdInputTensor
    else {
      return nil
    }
    defer { api.pointee.ReleaseValue(inputTensor) }

    // `Run`'s input/output name and value arrays are always exactly
    // 1 element in this module (one input tensor in, one output tensor
    // out per call) — passing `[element]`'s buffer pointer directly
    // avoids needing a generic N-element C-array bridging helper (and
    // the force-unwrap one would otherwise need to assert a
    // never-actually-empty buffer is non-empty).
    var outputTensor: OpaquePointer?
    let runResult: OrtStatusPtr? = inputName.withCString { inputNameCString -> OrtStatusPtr? in
      outputName.withCString { outputNameCString -> OrtStatusPtr? in
        let inputNames: [UnsafePointer<CChar>?] = [inputNameCString]
        let outputNames: [UnsafePointer<CChar>?] = [outputNameCString]
        let inputValues: [OpaquePointer?] = [inputTensor]
        return inputNames.withUnsafeBufferPointer { inputNamesBuffer in
          outputNames.withUnsafeBufferPointer { outputNamesBuffer in
            inputValues.withUnsafeBufferPointer { inputValuesBuffer in
              withUnsafeMutablePointer(to: &outputTensor) { outputValues in
                api.pointee.Run(
                  session, nil, inputNamesBuffer.baseAddress, inputValuesBuffer.baseAddress, 1,
                  outputNamesBuffer.baseAddress, 1, outputValues)
              }
            }
          }
        }
      }
    }
    guard OrtStatusChecking.succeeded(runResult, api: api), let outputTensor else { return nil }
    defer { api.pointee.ReleaseValue(outputTensor) }

    var dataPointer: UnsafeMutableRawPointer?
    let dataStatus = api.pointee.GetTensorMutableData(outputTensor, &dataPointer)
    guard OrtStatusChecking.succeeded(dataStatus, api: api), let dataPointer else { return nil }

    let shape = ortTensorShape(of: outputTensor)
    let elementCount = shape.reduce(1) { $0 * Int($1) }
    guard elementCount > 0 else { return nil }
    let typedPointer = dataPointer.bindMemory(to: Float.self, capacity: elementCount)
    let data = Array(UnsafeBufferPointer(start: typedPointer, count: elementCount))
    return (data: data, shape: shape)
  }

  /// Runs the detection model. Input: one NCHW image tensor, already
  /// resized/padded by the caller (`OCRPipeline`) to
  /// `OCRTierConfiguration.detectionInputLongSide` and normalized.
  ///
  /// `outputName` VERIFIED (not assumed) as of P8-B against a real
  /// PP-OCRv5 mobile detection ONNX export — see this task's handoff notes
  /// (`.claude/logs/senior-dev.md`) for the exact source (RapidOCR's
  /// ModelScope-hosted conversion, `ch_PP-OCRv5_det_mobile.onnx`) and how
  /// it was checked (`onnxruntime.InferenceSession(...).get_outputs()`).
  /// That export's real output name is the generic `fetch_name_0` — NOT
  /// the previously-assumed `sigmoid_0.tmp_0` op-derived name (a
  /// reasonable but wrong guess made before any real model was
  /// available). If `clipnest-ocr` ever ships a DIFFERENT PP-OCRv5 ONNX
  /// conversion, reconcile this one string against that export's own
  /// `netron`/`get_outputs()` output — exactly the one-line change this
  /// function's parameterization was designed for.
  func runDetection(inputData: [Float], inputShape: [Int64]) -> (
    data: [Float], shape: [Int64]
  )? {
    run(
      session: detectionSession, inputName: "x", outputName: "fetch_name_0",
      inputData: inputData, inputShape: inputShape)
  }

  /// Runs the recognition model on a batch of cropped, 48px-tall text
  /// lines (already stacked into one NCHW tensor by the caller).
  ///
  /// `outputName` VERIFIED as of P8-B against the same source's recognition
  /// export (`ch_PP-OCRv5_rec_mobile.onnx`) — also the generic
  /// `fetch_name_0`, not the previously-assumed `softmax_0.tmp_0`. See
  /// `runDetection`'s doc comment for the full reconciliation note.
  func runRecognition(inputData: [Float], inputShape: [Int64]) -> (
    data: [Float], shape: [Int64]
  )? {
    run(
      session: recognitionSession, inputName: "x", outputName: "fetch_name_0",
      inputData: inputData, inputShape: inputShape)
  }

  /// Runs the text-line orientation classifier. Only callable when
  /// `hasOrientationSession` is true (the tier enabled it); returns
  /// `nil` otherwise rather than crashing on a force-unwrap of a session
  /// that was never created.
  ///
  /// `outputName` VERIFIED as of P8-B against the same source's PP-OCR
  /// mobile orientation classifier export (PP-OCRv5 has no dedicated
  /// classifier of its own — RapidOCR's own default config reuses PP-OCR's
  /// standard mobile text-line classifier, `ch_ppocr_mobile_v2.0_cls_mobile
  /// .onnx`, for every PP-OCR version): the real output name is
  /// `save_infer_model/scale_0.tmp_1`, not the previously-assumed
  /// `softmax_0.tmp_0`.
  func runOrientationClassifier(inputData: [Float], inputShape: [Int64]) -> (
    data: [Float], shape: [Int64]
  )? {
    guard let orientationSession else { return nil }
    return run(
      session: orientationSession, inputName: "x",
      outputName: "save_infer_model/scale_0.tmp_1", inputData: inputData, inputShape: inputShape)
  }

  private func ortTensorShape(of tensor: OpaquePointer) -> [Int64] {
    var typeAndShapeInfo: OpaquePointer?
    guard
      OrtStatusChecking.succeeded(
        api.pointee.GetTensorTypeAndShape(tensor, &typeAndShapeInfo), api: api),
      let typeAndShapeInfo
    else { return [] }
    defer { api.pointee.ReleaseTensorTypeAndShapeInfo(typeAndShapeInfo) }

    var dimensionCount: Int = 0
    guard
      OrtStatusChecking.succeeded(
        api.pointee.GetDimensionsCount(typeAndShapeInfo, &dimensionCount), api: api)
    else { return [] }
    guard dimensionCount > 0 else { return [] }

    var dimensions = [Int64](repeating: 0, count: dimensionCount)
    let dimensionsStatus = dimensions.withUnsafeMutableBufferPointer { buffer in
      api.pointee.GetDimensions(typeAndShapeInfo, buffer.baseAddress, dimensionCount)
    }
    guard OrtStatusChecking.succeeded(dimensionsStatus, api: api) else { return [] }
    return dimensions
  }
}

/// Every fallible `OrtApi` call returns an `OrtStatusPtr` (NULL on
/// success, a status object that must be released otherwise) — this is
/// the ONE place that pattern is handled, so every call site above is a
/// simple `guard OrtStatusChecking.succeeded(...)`.
enum OrtStatusChecking {
  static func succeeded(_ status: OrtStatusPtr?, api: UnsafePointer<OrtApi>) -> Bool {
    guard let status else { return true }
    // Metadata-only per this codebase's logging discipline — an ORT
    // error message describes model/tensor plumbing, never clipboard
    // content, but this module doesn't have an injected logger at this
    // low a layer; the message is discarded rather than printed
    // unconditionally, to avoid a stray stdout/stderr write from a
    // background library call. Revisit if `OnnxTextRecognizer`'s own
    // `ClipnestLogger` needs to surface these for diagnostics.
    api.pointee.ReleaseStatus(status)
    return false
  }
}
