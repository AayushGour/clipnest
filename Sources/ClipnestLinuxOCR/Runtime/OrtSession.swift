// OrtSession.swift
//
// P6-C (Linux OCR): the actual ONNX Runtime C API calls — creating the
// shared `OrtEnv`, per-model `OrtSession`s, and running inference.
//
// UNVERIFIED AGAINST REAL HEADERS — see `OrtEnvironment.swift`'s doc
// comment for why (no `onnxruntime_c_api.h` anywhere in this task's
// environment). Written directly from the C API's well-documented, stable
// public shape (`OrtApiBase`/`OrtApi` function-pointer tables,
// `OrtGetApiBase()->GetApi(ORT_API_VERSION)`), matching this task's mandate
// to use ONLY the C API, never the C++ headers (the C++ API wraps this
// same C struct and would drag a libstdc++ ABI dependency across the Swift
// boundary that the C API does not have).
//
// This entire file is compiled ONLY when `COnnxRuntime`'s headers actually
// resolved — see `OrtRuntimeAvailability.swift`.
#if CLIPNEST_HAS_ONNXRUNTIME
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

    /// The ONNX Runtime API version this module was written against.
    /// Named per coding-standards.md rather than an inline literal;
    /// `ORT_API_VERSION` itself comes from the vendored header (when
    /// present) and takes precedence — this constant only documents intent.
    static let targetApiVersion: UInt32 = 21

    /// `OrtGetApiBase()->GetApi(...)` can legitimately return `NULL` if
    /// the linked `libonnxruntime.so`'s ABI version is older than
    /// `ORT_API_VERSION` — handled as an ordinary failure (`nil`), not a
    /// crash, exactly like every other fallible step in this pipeline.
    private static func loadApi() -> UnsafePointer<OrtApi>? {
      guard let base = OrtGetApiBase() else { return nil }
      guard let getApi = base.pointee.GetApi else { return nil }
      guard let apiPointer = getApi(ORT_API_VERSION) else { return nil }
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
      let status = api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "clipnest-ocr", &env)
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

      // Mandatory per this task's plan — see this function's doc comment.
      guard
        OrtStatusChecking.succeeded(
          api.pointee.AddSessionConfigEntry(options, "session.intra_op.allow_spinning", "0"),
          api: api)
      else { return nil }

      var session: OpaquePointer?
      let status = api.pointee.CreateSession(environment, modelPath, options, &session)
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
    /// `inputName`/`outputName` are the exported ONNX graph's tensor names
    /// — UNVERIFIED against a real exported PP-OCRv5 ONNX file (none is
    /// available in this environment); PP-OCR's own export tooling
    /// conventionally names these "x" (input) and the op-derived default
    /// output name, but a real model's `netron`-inspected names should
    /// replace these before this code is exercised against an actual
    /// model. Kept as parameters (not hardcoded deep inside) specifically
    /// so that reconciliation is a one-line call-site change, not a rewrite.
    private func run(
      session: OpaquePointer, inputName: String, outputName: String, inputData: [Float],
      inputShape: [Int64]
    ) -> (data: [Float], shape: [Int64])? {
      dispatchPrecondition(condition: .onQueue(OrtEnvironment.shared.queue))

      var createdInputTensor: OpaquePointer?
      let tensorStatus = inputData.withUnsafeBufferPointer { buffer -> OrtStatusPtr? in
        inputShape.withUnsafeBufferPointer { shapeBuffer in
          api.pointee.CreateTensorWithDataAsOrtValue(
            memoryInfo, UnsafeMutableRawPointer(mutating: buffer.baseAddress),
            buffer.count * MemoryLayout<Float>.stride, shapeBuffer.baseAddress, shapeBuffer.count,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &createdInputTensor)
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
    func runDetection(inputData: [Float], inputShape: [Int64]) -> (
      data: [Float], shape: [Int64]
    )? {
      run(
        session: detectionSession, inputName: "x", outputName: "sigmoid_0.tmp_0",
        inputData: inputData, inputShape: inputShape)
    }

    /// Runs the recognition model on a batch of cropped, 48px-tall text
    /// lines (already stacked into one NCHW tensor by the caller).
    func runRecognition(inputData: [Float], inputShape: [Int64]) -> (
      data: [Float], shape: [Int64]
    )? {
      run(
        session: recognitionSession, inputName: "x", outputName: "softmax_0.tmp_0",
        inputData: inputData, inputShape: inputShape)
    }

    /// Runs the text-line orientation classifier. Only callable when
    /// `hasOrientationSession` is true (the tier enabled it); returns
    /// `nil` otherwise rather than crashing on a force-unwrap of a session
    /// that was never created.
    func runOrientationClassifier(inputData: [Float], inputShape: [Int64]) -> (
      data: [Float], shape: [Int64]
    )? {
      guard let orientationSession else { return nil }
      return run(
        session: orientationSession, inputName: "x", outputName: "softmax_0.tmp_0",
        inputData: inputData, inputShape: inputShape)
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

#endif
