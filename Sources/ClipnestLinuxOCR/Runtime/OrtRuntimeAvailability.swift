// OrtRuntimeAvailability.swift
//
// P6-C / P8-B (Linux OCR): the ONE place this module asks "is ONNX Runtime
// actually usable right now?" — every other file that touches the ONNX
// Runtime C API (`OrtEnvironment.swift`, `OrtSession.swift`,
// `OCRPipeline.swift`, `OnnxTextRecognizer.swift`) is gated behind this
// same check.
//
// HISTORY (superseded design, kept here for context): this used to be a
// compile-time `CLIPNEST_HAS_ONNXRUNTIME` flag, because `import
// COnnxRuntime` textually appearing anywhere hard-errored the build the
// moment the real `onnxruntime_c_api.h` header was unreachable (see D66 in
// `.claude/project-context.md`, and this module's own git history for the
// exact Docker transcript that surfaced it). That is no longer true:
// `Sources/COnnxRuntime/shim.h` is now fully self-contained (see its own
// top comment) and never depends on the real header being present
// anywhere, so `import COnnxRuntime` always resolves and this module's
// ORT-calling code (`OrtSession.swift`, `OrtEnvironment.swift`,
// `OCRPipeline.swift`) is unconditionally compiled in on Linux — it is
// genuinely present in the `clipnest` binary now, matching this task's
// mandate ("OCR present in the binary but reporting itself unavailable
// when the .so is absent").
//
// WHAT THIS CHECKS NOW: whether the real `libonnxruntime.so.1` was found
// and `dlopen`ed successfully (see `OrtLibrary.swift`) — a RUNTIME fact,
// not a build-time one. `clipnest` only `Recommends:` the separate
// `clipnest-ocr` package (see `Package.swift`'s `COnnxRuntime` comment)
// specifically so this is routinely `false` on a machine that never
// installed it — an ordinary, expected state, never a crash: when `false`,
// `OnnxTextRecognizer` degrades to always returning `nil` from
// `recognizeText`, matching `TextRecognizing`'s documented "returns nil on
// failure" contract exactly.
public enum OrtRuntimeAvailability {
  /// `true` iff `OrtLibrary.isLoaded` — i.e. `libonnxruntime.so.1` was
  /// found on this machine (see `OrtLibrary.searchDirectories`) and
  /// successfully `dlopen`ed. Resolved once per process, exactly like the
  /// `dlopen` call it wraps.
  public static var isAvailable: Bool {
    OrtLibrary.isLoaded
  }
}
