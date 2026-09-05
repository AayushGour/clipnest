// OrtRuntimeAvailability.swift
//
// P6-C (Linux OCR): the ONE place this module asks "is ONNX Runtime actually
// linkable right now?" — every other file that touches the ONNX Runtime C
// API (`OrtEnvironment.swift`, `OrtSession.swift`, `OCRPipeline.swift`,
// `OnnxTextRecognizer.swift`) is gated behind this same check.
//
// WHY A CUSTOM FLAG, NOT `#if canImport(COnnxRuntime)`: `canImport` was the
// first thing tried here, and it does NOT work for this case — verified
// empirically, not assumed. `COnnxRuntime` (see `Package.swift`) is a
// `systemLibrary` target whose `shim.h` unconditionally `#include`s
// `<onnxruntime_c_api.h>` (not in Ubuntu's repositories, not vendored into
// this repo — see that target's own comment). The moment ANY `.swift` file
// in this module has a plain `import COnnxRuntime` — even wrapped in
// `#if canImport(COnnxRuntime) { import COnnxRuntime } #endif` — SwiftPM's
// build (confirmed via this task's own Docker verification, plain
// `swift:6.0-jammy`, no vendored headers) has Clang eagerly try to build
// the module to answer the `canImport` query, hit the missing header, and
// emit a HARD, non-recoverable "could not build C module 'COnnxRuntime'"
// error — not a graceful `false`. This is a real, documented Swift/Clang
// interop gap: `canImport` only degrades gracefully when a module is
// unreachable/unnamed on the search path, NOT when a module IS reachable
// (it's a real target dependency) but its underlying header is broken —
// see this task's handoff notes for the exact Docker transcript that
// surfaced this.
//
// The fix is the task's OWN suggested fallback: "a CLIPNEST_HAS_ONNXRUNTIME
// flag" — a dumb, textual Swift compilation condition that never asks Clang
// to resolve anything. `import COnnxRuntime` only appears in source text
// when `CLIPNEST_HAS_ONNXRUNTIME` is defined; when it's undefined (the
// default — nothing in `Package.swift` defines it today), the import
// statement is never even seen by the compiler, so Clang never attempts to
// build the module, regardless of `COnnxRuntime` still being declared as a
// target dependency (a target DEPENDENCY only makes a module available on
// the search path; declaring it is not the same as importing it, and
// Swift/Clang do not eagerly validate an unimported dependency).
//
// REMAINING GAP (Package.swift-level, out of this task's scope — see the
// "do NOT touch Package.swift" constraint): for the real `clipnest-ocr`
// build (vendored headers present) to actually USE ONNX Runtime, whoever
// owns `Package.swift` needs to add, to the `ClipnestLinuxOCR` target:
// `swiftSettings: [.define("CLIPNEST_HAS_ONNXRUNTIME", .when(platforms: [.linux]))]`
// (or an unconditional `.define(...)`, if this target is never built
// off-Linux). Until that one line lands, `ClipnestLinuxOCR` compiles
// correctly everywhere but always resolves to "OCR unavailable" — a
// strictly safe default, never a broken build.
public enum OrtRuntimeAvailability {
  /// `true` only when built with `-DCLIPNEST_HAS_ONNXRUNTIME` (see this
  /// file's doc comment for exactly where that needs to be defined). When
  /// `false`, `OnnxTextRecognizer` degrades to always returning `nil` from
  /// `recognizeText` — matching `TextRecognizing`'s documented "returns nil
  /// on failure" contract exactly, so a build without vendored ONNX Runtime
  /// headers (this task's own Docker verification, or a user's system
  /// missing the `clipnest-ocr` package `clipnest` only `Recommends`)
  /// degrades gracefully rather than failing to build or crashing at
  /// runtime.
  public static let isAvailable: Bool = {
    #if CLIPNEST_HAS_ONNXRUNTIME
      return true
    #else
      return false
    #endif
  }()
}
