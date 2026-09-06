// OCROrtLibraryTests.swift
//
// P8-B (Linux OCR: actually enable it): unit tests for `OrtLibrary` — the
// `dlopen`/`dlsym` resolution of ONNX Runtime that replaced the previous
// link-time `link "onnxruntime"` dependency (see decision D66 in
// `.claude/project-context.md`). These tests exercise the parts of
// `OrtLibrary` that don't depend on whether THIS machine happens to have
// `libonnxruntime.so.1` installed — the injectable `libraryName`/
// `searchDirectories` parameters exist specifically so this suite is
// deterministic in CI (no real ONNX Runtime present) and on a dev/packaging
// box (real ONNX Runtime present) alike.
import Foundation
import Testing

@testable import ClipnestLinuxOCR

@Suite("OrtLibrary")
struct OCROrtLibraryTests {

  @Test("should_build_one_candidate_path_per_search_directory_in_order")
  func candidatePaths_joinsEachDirectoryWithLibraryName() {
    let paths = OrtLibrary.candidatePaths(
      libraryName: "libexample.so.1", searchDirectories: ["/usr/lib/clipnest", "/usr/local/lib"])
    #expect(paths == ["/usr/lib/clipnest/libexample.so.1", "/usr/local/lib/libexample.so.1"])
  }

  @Test("should_return_empty_candidate_list_for_empty_search_directories")
  func candidatePaths_emptySearchDirectories() {
    let paths = OrtLibrary.candidatePaths(libraryName: "libexample.so.1", searchDirectories: [])
    #expect(paths.isEmpty)
  }

  @Test("should_return_nil_when_no_matching_library_exists_anywhere")
  func open_returnsNilWhenLibraryIsNotInstalledAnywhere() {
    // A name guaranteed never to exist on any real filesystem, searched in
    // directories guaranteed to exist but never contain it (or not exist
    // at all) — deterministic regardless of whether the CI/dev machine
    // running this test happens to have the real ONNX Runtime installed.
    let handle = OrtLibrary.open(
      libraryName: "libclipnest-ocr-test-nonexistent-9f3c2a.so.1",
      searchDirectories: ["/nonexistent-clipnest-ocr-test-directory", "/usr/lib/clipnest"])
    #expect(handle == nil)
  }

  @Test("should_report_apiBase_as_nil_when_the_library_never_loaded")
  func apiBase_isNilWhenLibraryUnavailable() {
    // `OrtLibrary.apiBase()` always resolves against the process-wide
    // cached handle (real search paths, real SONAME) — on a machine
    // without `clipnest-ocr` installed (the common case for `swift test`
    // outside the packaging container), that handle is `nil`, so
    // `apiBase()` must degrade to `nil` too, never crash.
    if !OrtLibrary.isLoaded {
      #expect(OrtLibrary.apiBase() == nil)
    }
  }

  @Test("should_expose_isLoaded_as_a_plain_bool_without_crashing")
  func isLoaded_neverCrashes() {
    // Whether ONNX Runtime happens to be installed on the machine running
    // this test is environment-dependent (true inside the packaging
    // verification container, false on a bare CI runner) — this test only
    // asserts the check itself is safe to call repeatedly.
    _ = OrtLibrary.isLoaded
    _ = OrtLibrary.isLoaded
    #expect(Bool(true))
  }

  @Test("should_create_a_real_OrtEnv_end_to_end_when_ONNX_Runtime_is_actually_installed")
  func createEnvironment_succeedsWhenRealLibraryIsInstalled() {
    // Deliberately conditional, not skipped: on a bare CI runner (no
    // `clipnest-ocr` installed), `OrtLibrary.isLoaded` is `false` and this
    // test asserts nothing beyond "no crash" — the real, unconditional
    // proof this exercises lives in this task's Docker verification
    // (`.claude/logs/senior-dev.md`, P8-B), where the real, vendored
    // `libonnxruntime.so.1` (`packaging/linux/vendor/onnxruntime`) IS
    // installed at `/usr/lib/clipnest/` and this branch runs for real:
    // `OrtGetApiBase` (dlsym) -> `GetApi(28)` -> `CreateEnv` all the way
    // through the real ONNX Runtime C API, not a stub.
    if OrtLibrary.isLoaded {
      let env = OrtSessionSet.createEnvironment()
      #expect(env != nil)
    }
  }
}
