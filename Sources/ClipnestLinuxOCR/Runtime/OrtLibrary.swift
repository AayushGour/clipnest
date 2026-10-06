import COnnxRuntime
import Foundation

// OrtLibrary.swift
//
// P8-B (Linux OCR: actually enable it): resolves the real ONNX Runtime
// shared library and its `OrtGetApiBase()` entry point at RUNTIME, via
// `dlopen`/`dlsym` — never a link-time dependency. This is this module's
// direct answer to decision D66 in `.claude/project-context.md`
// ("`Sources/COnnxRuntime/module.modulemap` hard-links `libonnxruntime.so.1`,
// which is incompatible with `clipnest` merely `Recommends:`-ing
// `clipnest-ocr`") and mirrors the sanctioned precedent already established
// in this codebase for exactly this class of problem: D59's
// `Sources/ClipnestPlatformLinux/Input/UInputDevice.swift` `RawIoctl`,
// which resolves `ioctl` the same way (`dlopen` + `dlsym` +
// `unsafeBitCast` to an exact `@convention(c)` shape) because Swift cannot
// call it directly either — there the reason is `ioctl`'s C variadic
// signature, here it's this file's own "must not appear in `DT_NEEDED`"
// requirement, but the fix is identical in shape.
//
// `libonnxruntime.so.1` is the SONAME symlink both this task's vendored
// tree (`packaging/linux/vendor/onnxruntime/<arch>/lib/`) and the real
// `clipnest-ocr` `.deb` ship — see that directory's own `SOURCE.md`.
#if canImport(Glibc)
  import Glibc
#endif

enum OrtLibrary {

  /// The SONAME `dlopen` resolves — NOT the unversioned, build-time-only
  /// `libonnxruntime.so` dev symlink (deliberately never vendored/packaged;
  /// see `packaging/linux/vendor/onnxruntime/SOURCE.md`).
  static let sonameLibraryName = "libonnxruntime.so.1"

  /// Absolute directories tried, in order, via an explicit path BEFORE
  /// falling back to a bare `dlopen(sonameLibraryName, ...)` (which itself
  /// still walks the dynamic linker's own normal search — `LD_LIBRARY_PATH`,
  /// `/etc/ld.so.cache`, the default trusted paths — so this list is pure
  /// belt-and-braces, not a replacement for that search).
  /// `/usr/lib/clipnest` is where the `clipnest-ocr` package installs its
  /// own private copy of `libonnxruntime.so.1` (per this task's plan) —
  /// specifically OUTSIDE the system-wide linker cache, so installing
  /// `clipnest-ocr` never runs `ldconfig` or risks colliding with an
  /// unrelated package's own differently-versioned ONNX Runtime. The
  /// multiarch `/usr/lib/<triplet>` directories are the two triplets this
  /// project actually packages for (`packaging/linux/vendor/onnxruntime`'s
  /// `amd64`/`arm64` split) — trying both unconditionally is harmless (a
  /// missing directory's `dlopen` attempt just fails and moves on).
  static let searchDirectories = [
    "/usr/lib/clipnest",
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/usr/local/lib",
  ]

  /// The ordered list of absolute paths `open(libraryName:searchDirectories:)`
  /// tries before its final bare-name fallback. A pure function (no
  /// `dlopen` call), so tests can verify the search-order logic
  /// deterministically without depending on what happens to be installed
  /// on the machine running `swift test`.
  static func candidatePaths(
    libraryName: String = sonameLibraryName, searchDirectories: [String] = searchDirectories
  ) -> [String] {
    searchDirectories.map { "\($0)/\(libraryName)" }
  }

  /// Attempts `dlopen` down `candidatePaths(...)`, then the bare
  /// `libraryName` (deferring to the dynamic linker's own search). Returns
  /// `nil` — never crashes, never throws — the instant every attempt fails,
  /// which is the ordinary, expected shape of "a machine without
  /// `clipnest-ocr` installed." `libraryName`/`searchDirectories` are
  /// injectable so tests can exercise the "never found" path
  /// deterministically (e.g. a nonsense name + an empty search list)
  /// without depending on whether THIS machine happens to have ONNX
  /// Runtime installed.
  static func open(
    libraryName: String = sonameLibraryName, searchDirectories: [String] = searchDirectories
  ) -> UnsafeMutableRawPointer? {
    #if canImport(Glibc)
      for path in candidatePaths(libraryName: libraryName, searchDirectories: searchDirectories) {
        if let handle = path.withCString({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }) {
          return handle
        }
      }
      return libraryName.withCString { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
    #else
      return nil
    #endif
  }

  /// Resolved exactly once per process — `dlopen`ing the same SONAME again
  /// only bumps glibc's internal refcount and returns the same handle, and
  /// a library that was missing at process start does not become present
  /// mid-process (matching `OrtEnvironment.shared`'s own "resolve once"
  /// shape). `nonisolated(unsafe)`: this pointer is the process-lifetime,
  /// never-mutated-after-initialization address of a `dlopen` handle,
  /// resolved exactly once via `static let`'s thread-safe lazy
  /// initialization, then only ever read — the same justification
  /// `RawIoctl.symbol` (D59) already documents for the identical shape.
  nonisolated(unsafe) private static let cachedHandle: UnsafeMutableRawPointer? = open()

  /// `true` iff `libonnxruntime.so.1` was found and successfully loaded —
  /// the ONE fact `OrtRuntimeAvailability.isAvailable` reports (see that
  /// type's doc comment).
  static var isLoaded: Bool { cachedHandle != nil }

  private typealias GetApiBaseFunction = @convention(c) () -> UnsafePointer<OrtApiBase>?

  /// Resolves and calls `OrtGetApiBase()` via `dlsym` — see this file's top
  /// comment for why it is never declared as a normal linked C function.
  /// Returns `nil` if the library never loaded, or (extremely unlikely,
  /// but handled rather than force-unwrapped) the loaded `.so` doesn't
  /// export the symbol at all.
  static func apiBase() -> UnsafePointer<OrtApiBase>? {
    #if canImport(Glibc)
      guard let cachedHandle else { return nil }
      guard let symbol = "OrtGetApiBase".withCString({ dlsym(cachedHandle, $0) }) else {
        return nil
      }
      return unsafeBitCast(symbol, to: GetApiBaseFunction.self)()
    #else
      return nil
    #endif
  }
}
