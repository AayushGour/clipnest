// shim.h — a self-authored, minimal ONNX Runtime C API surface. This file
// does NOT `#include <onnxruntime_c_api.h>` (the real, upstream header) —
// see decision D66 in `.claude/project-context.md` for why, and this file's
// own comments below for exactly how this was derived and verified.
//
// WHY NOT THE REAL HEADER: two independent problems, both dated 2026-09-05
// (D66 + the "earlier finding" it records), pointed at the same fix:
//
//  1. (Link-time) The previous `module.modulemap` did `link "onnxruntime"`,
//     which — the moment this module compiled in at all — made the final
//     `clipnest` binary carry a hard `DT_NEEDED libonnxruntime.so.1`. Debian
//     tooling (`dpkg-shlibdeps`) reads that straight off the ELF binary and
//     promotes it to a hard `Depends:`, which breaks `clipnest`'s intended
//     "OCR is an optional `Recommends:`" packaging shape — forcing a ~45MB
//     runtime onto every user, including those who never touch OCR. Fixed
//     by resolving the ONNX Runtime C API via `dlopen`/`dlsym` at runtime
//     instead (see `OrtLibrary.swift`) — this module carries NO `link`
//     directive at all now (see `module.modulemap`).
//
//  2. (Build-time) The real `onnxruntime_c_api.h` was, at the time D66 was
//     written, not present anywhere this module's build could reach except
//     inside `packaging/linux/vendor/onnxruntime/<arch>/include/` — a
//     directory outside `Sources/`, not on any header search path this
//     target's `Package.swift` `systemLibrary` declaration configures. Once
//     `#include <onnxruntime_c_api.h>` is reachable in source, Clang tries
//     to resolve it EAGERLY the moment the module is imported (even behind
//     `#if canImport(COnnxRuntime)` — verified empirically, see
//     `OrtRuntimeAvailability.swift`'s history) and hard-errors if it's
//     missing — there is no graceful "false" for a declared-but-unbuildable
//     module. Fixed here by not depending on that header at all: this file
//     is fully self-contained (needs only the standard `<stddef.h>`/
//     `<stdint.h>` headers every C toolchain ships), so `import
//     COnnxRuntime` can never fail to resolve, on ANY machine, regardless
//     of whether `clipnest-ocr` (which vendors the real runtime `.so`, not
//     headers — headers are a build-time-only concern) is installed.
//
// WHAT'S DECLARED, AND HOW IT STAYS ABI-CORRECT: `OrtApi` (below) is
// ONNX Runtime's C API — a single flat vtable (`struct OrtApi`) of ~400
// function pointers, handed back by `OrtGetApiBase()->GetApi(ORT_API_VERSION)`.
// Every member's byte OFFSET into that struct is fixed purely by its
// declaration order in ONNX Runtime's own header — ONNX Runtime's own
// documented ABI-compatibility promise is that this order, once shipped in
// a release, never changes (only new members are ever appended at the
// end). Reconstructing this vtable from scratch means the STRUCTURE must
// match exactly, but — because every single member is a plain, one-word
// (8-byte) pointer on every ABI this project targets (x86_64/arm64 Linux:
// a function pointer and a `void*` data pointer are identical in size and
// alignment) — a member this module never calls does not need its real
// name or real signature transcribed by hand, only its correct COUNT and
// POSITION. Below, unused runs of members are collapsed into `void
// *_reservedN[count]` filler arrays (an array's N elements are laid out
// with zero interior padding, so an N-element filler array is
// layout-identical to N individual placeholder pointer fields) — only the
// 18 members `Sources/ClipnestLinuxOCR/Runtime/OrtSession.swift` actually
// calls are given their real, verified name and C signature. This keeps
// the file auditable (18 real declarations, not ~400) while remaining
// exactly ABI-correct.
//
// VERIFIED, NOT GUESSED: every real member's name, position, and signature
// below was extracted mechanically (not hand-transcribed/eyeballed) from
// the actual vendored header —
// `packaging/linux/vendor/onnxruntime/amd64/include/onnxruntime_c_api.h`
// (ONNX Runtime 1.28.1, MIT — see that directory's own `SOURCE.md`), whose
// `#define ORT_API_VERSION` is 28 for this exact release (previously
// assumed 21 in this module's earlier "UNVERIFIED AGAINST REAL HEADERS"
// pass — see `OrtSession.swift`'s `targetApiVersion`, now corrected). A
// small Python script walked `struct OrtApi { ... }`'s body (lines
// 1294–7520 of that header), matched every one of its FOUR possible
// member-declaration shapes (`ORT_API2_STATUS(Name, ...)`,
// `ORT_CLASS_RELEASE(X)`, `ORT_API_T(ReturnType, Name, ...)`, and a raw
// `Type(ORT_API_CALL* Name)(...)` field) in textual order, and printed
// each member's exact 0-based index — 424 total members for this release.
// Each of the 18 real declarations below was then independently
// cross-checked against that header's own line numbers to confirm
// monotonically increasing position (e.g. `CreateEnv` at header line 1335
// → index 3, `CreateSession` at line 1389 → index 7, …
// `AddSessionConfigEntry` at line 2845 → index 130) before being placed
// here. The amd64 and arm64 vendored headers are byte-identical (checked
// via `diff`), so this layout holds for both architectures this project
// packages.
//
// CAUGHT BY THE COMPILER, NOT ASSUMED: the script's first pass missed the
// `ORT_API_T(...)` shape entirely (11 members use it, all AFTER
// `AddSessionConfigEntry` in this header — see the real header's
// `MemoryInfoGetDeviceMemType`/`ExternalInitializerInfo_*`/etc. members),
// undercounting the true total as 413. This was caught empirically, not by
// re-reading more carefully: a throwaway C program computed
// `offsetof(struct OrtApi, X)` for all 18 real members named below against
// BOTH the real, unmodified vendored header AND this file, and compared —
// every one of the 18 matched exactly (proving the layout up to
// `AddSessionConfigEntry` was always correct), but `sizeof(struct
// OrtApi)` itself disagreed (413 vs. the real 424), which is what
// surfaced the missed shape. Fixed by widening the trailing
// `_reservedN` filler to the real, verified total. This mismatch could
// never have affected any of the 18 real calls this module makes — they
// all sit before the point where the miscount occurred — but the count is
// corrected anyway so this comment stays honest.
//
// This same "flat vtable, verified fixed indices" approach is exactly
// what `OrtApiBase` (2 members, unchanged since ONNX Runtime's C API's
// introduction) does NOT need — it's small and stable enough to declare
// with its two real, named fields directly.
#ifndef CLIPNEST_CONNXRUNTIME_SHIM_H
#define CLIPNEST_CONNXRUNTIME_SHIM_H

#include <stddef.h>
#include <stdint.h>

// Opaque ONNX Runtime handle types this module ever holds a pointer to.
// Never defined (only forward-declared) — every use on the Swift side is
// already behind a pointer (`OpaquePointer`/`UnsafeMutablePointer<T>`), so
// their true internal layout (owned entirely by the loaded `.so`, never
// this module) is irrelevant here.
typedef struct OrtEnv OrtEnv;
typedef struct OrtStatus OrtStatus;
typedef struct OrtMemoryInfo OrtMemoryInfo;
typedef struct OrtSession OrtSession;
typedef struct OrtSessionOptions OrtSessionOptions;
typedef struct OrtValue OrtValue;
typedef struct OrtRunOptions OrtRunOptions;
typedef struct OrtTensorTypeAndShapeInfo OrtTensorTypeAndShapeInfo;

// `OrtStatus*` — ONNX Runtime's own alias for a fallible call's return
// value (NULL on success). Transcribed verbatim from the real header's
// non-Windows definition (`typedef OrtStatus* OrtStatusPtr;`).
typedef OrtStatus *OrtStatusPtr;

// The four small, stable enums this module's 18 real `OrtApi` calls
// reference by value (never by struct offset, so — unlike `OrtApi`
// itself — only the specific enumerators actually passed need to carry
// their real, verified integer value; a plain C enum is `int`-sized
// regardless of how many of the real header's enumerators are included).
// Values transcribed verbatim from the real header.
typedef enum OrtLoggingLevel {
  ORT_LOGGING_LEVEL_VERBOSE = 0,
  ORT_LOGGING_LEVEL_INFO = 1,
  ORT_LOGGING_LEVEL_WARNING = 2,
  ORT_LOGGING_LEVEL_ERROR = 3,
  ORT_LOGGING_LEVEL_FATAL = 4,
} OrtLoggingLevel;

typedef enum OrtAllocatorType {
  OrtInvalidAllocator = -1,
  OrtDeviceAllocator = 0,
  OrtArenaAllocator = 1,
} OrtAllocatorType;

typedef enum OrtMemType {
  OrtMemTypeCPUInput = -2,
  OrtMemTypeCPUOutput = -1,
  OrtMemTypeDefault = 0,
} OrtMemType;

typedef enum ONNXTensorElementDataType {
  ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED = 0,
  ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT = 1,
} ONNXTensorElementDataType;

// Forward-declared (defined fully below) so `OrtApiBase.GetApi` can return
// a properly-typed `const OrtApi*` — exactly the real header's own
// ordering (it forward-declares `OrtApi` before defining `OrtApiBase`
// too), letting Swift see `GetApi` as a real `(UInt32) ->
// UnsafePointer<OrtApi>?` closure with no further reinterpretation needed
// at the call site.
typedef struct OrtApi OrtApi;

// The ONE C API entry point this module resolves via `dlsym` (never a
// normal linked call — see this file's own top comment, reason 1). Its
// signature is documented here for readers; it is NEVER declared `extern`
// (that would require the symbol at LINK time, defeating the entire point)
// — `OrtLibrary.swift` reinterprets the raw `dlsym` result as this exact
// `@convention(c)` shape instead.
//
//   const OrtApiBase *OrtGetApiBase(void);
//
// `OrtApiBase` itself is small (2 members) and has never changed across
// ONNX Runtime's history — declared with real, named fields directly,
// unlike the large `OrtApi` vtable below.
typedef struct OrtApiBase {
  const OrtApi *(*GetApi)(uint32_t version);
  const char *(*GetVersionString)(void);
} OrtApiBase;

// `OrtApi` — see this file's top comment for the full derivation. 424
// total members for ORT_API_VERSION 28 (ONNX Runtime 1.28.1); this
// module's own `OrtSession.swift` uses exactly 18 of them, each declared
// below at its verified real index.
struct OrtApi {
  void *_reserved0[3];  // indices 0..2
  OrtStatus *(*CreateEnv)(OrtLoggingLevel log_severity_level, const char *logid,
                          OrtEnv **out);  // index 3
  void *_reserved1[3];  // indices 4..6
  OrtStatus *(*CreateSession)(const OrtEnv *env, const char *model_path,
                              const OrtSessionOptions *options, OrtSession **out);  // index 7
  void *_reserved2[1];  // index 8
  OrtStatus *(*Run)(OrtSession *session, const OrtRunOptions *run_options,
                    const char *const *input_names, const OrtValue *const *inputs,
                    size_t input_len, const char *const *output_names, size_t output_names_len,
                    OrtValue **outputs);  // index 9
  OrtStatus *(*CreateSessionOptions)(OrtSessionOptions **options);  // index 10
  void *_reserved3[13];  // indices 11..23
  OrtStatus *(*SetIntraOpNumThreads)(OrtSessionOptions *options,
                                     int intra_op_num_threads);  // index 24
  void *_reserved4[24];  // indices 25..48
  OrtStatus *(*CreateTensorWithDataAsOrtValue)(const OrtMemoryInfo *info, void *p_data,
                                               size_t p_data_len, const int64_t *shape,
                                               size_t shape_len, ONNXTensorElementDataType type,
                                               OrtValue **out);  // index 49
  void *_reserved5[1];  // index 50
  OrtStatus *(*GetTensorMutableData)(OrtValue *value, void **out);  // index 51
  void *_reserved6[9];  // indices 52..60
  OrtStatus *(*GetDimensionsCount)(const OrtTensorTypeAndShapeInfo *info,
                                   size_t *out);  // index 61
  OrtStatus *(*GetDimensions)(const OrtTensorTypeAndShapeInfo *info, int64_t *dim_values,
                              size_t dim_values_length);  // index 62
  void *_reserved7[2];  // indices 63..64
  OrtStatus *(*GetTensorTypeAndShape)(const OrtValue *value,
                                      OrtTensorTypeAndShapeInfo **out);  // index 65
  void *_reserved8[3];  // indices 66..68
  OrtStatus *(*CreateCpuMemoryInfo)(OrtAllocatorType type, OrtMemType mem_type,
                                    OrtMemoryInfo **out);  // index 69
  void *_reserved9[23];  // indices 70..92
  void (*ReleaseStatus)(OrtStatus *input);  // index 93
  void (*ReleaseMemoryInfo)(OrtMemoryInfo *input);  // index 94
  void (*ReleaseSession)(OrtSession *input);  // index 95
  void (*ReleaseValue)(OrtValue *input);  // index 96
  void *_reserved10[2];  // indices 97..98
  void (*ReleaseTensorTypeAndShapeInfo)(OrtTensorTypeAndShapeInfo *input);  // index 99
  void (*ReleaseSessionOptions)(OrtSessionOptions *input);  // index 100
  void *_reserved11[29];  // indices 101..129
  OrtStatus *(*AddSessionConfigEntry)(OrtSessionOptions *options, const char *config_key,
                                      const char *config_value);  // index 130
  void *_reserved12[293];  // indices 131..423
};

#endif
