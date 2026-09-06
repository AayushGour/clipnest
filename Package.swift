// swift-tools-version: 6.0
import PackageDescription

// `platforms:` constrains APPLE deployment targets only — `SupportedPlatform`
// has no `.linux` case, so unlisted non-Apple platforms are supported by
// default. What actually gated the Linux build was source-level: unconditional
// Apple-only imports, resolved in Phase 1. Never lower the macOS floor without
// an architect decision (it is what SwiftData and SMAppService require).
let package = Package(
  name: "Clipnest",
  platforms: [.macOS(.v14)],
  products: [
    // Name preserved: ClipnestApp/project.yml depends on this product.
    .library(name: "ClipnestCore", targets: ["ClipnestCore"]),
    .library(name: "ClipnestSQLite", targets: ["ClipnestSQLite"]),
    // Phase 3 (Linux port): the platform-neutral view-model layer, shared by
    // the macOS SwiftUI app and the future Linux GTK app. `ClipnestObservation`
    // is a transitive dependency of this target (not its own product — no
    // consumer needs it directly), pulled in automatically by SwiftPM.
    .library(name: "ClipnestViewModels", targets: ["ClipnestViewModels"]),
  ],
  dependencies: [
    // Linked ONLY off-Apple; Apple platforms keep the system CryptoKit.
    // Resolved on every host so Package.resolved stays identical, but never
    // linked into the macOS app.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .target(
      name: "ClipnestCore",
      dependencies: [
        .product(
          name: "Crypto", package: "swift-crypto",
          condition: .when(platforms: [.linux, .windows]))
      ]
    ),
    // No `pkgConfig:` — sqlite3.pc is absent from the macOS SDK and would fail
    // resolution there. `link "sqlite3"` resolves against the SDK on macOS and
    // libsqlite3-dev on Ubuntu.
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    // Builds on macOS too, deliberately: libsqlite3 ships in the macOS SDK, so
    // the Linux store is validated by the shared ClipStore/SnippetStore
    // contract suites on the existing macOS CI runner, before any Linux runner
    // or GTK code exists. macOS PRODUCTION still uses SwiftData.
    .target(name: "ClipnestSQLite", dependencies: ["ClipnestCore", "CSQLite"]),
    .testTarget(
      name: "ClipnestCoreTests", dependencies: ["ClipnestCore", "ClipnestSQLite"]),
    // Phase 3 (Linux port): Combine-free `ObservableObject`/`@Published`/
    // `objectWillChange` polyfill, compiled in only where `!canImport(Combine)`
    // (i.e. Linux) — see `ObservableObject.swift`'s doc comment. Empty (zero
    // public symbols) on Apple platforms, where the real `Combine` is used
    // instead.
    .target(name: "ClipnestObservation"),
    // Phase 3 (Linux port): the platform-neutral view-model layer extracted
    // from `ClipnestApp` — `PickerViewModel`, `SettingsStore`,
    // `OCRBackfillViewModel`, `UpdateChecker`, and their pure supporting
    // types. Every AppKit/Combine dependency is either an injected closure
    // (already true before this extraction) or resolved through
    // `PlatformDefaults`/`ClipnestObservation`.
    .target(name: "ClipnestViewModels", dependencies: ["ClipnestCore", "ClipnestObservation"]),
    .testTarget(
      name: "ClipnestViewModelsTests", dependencies: ["ClipnestViewModels", "ClipnestCore"]),
  ]
)

// Linux-only graph, guarded at MANIFEST level. Package.swift is host-compiled
// Swift, so on macOS these targets do not exist at all — Xcode never sees the
// GTK/X11/ONNX system libraries and can never try to resolve or link them.
#if os(Linux)
  package.products += [
    .executable(name: "clipnest", targets: ["ClipnestLinuxApp"])
  ]
  package.targets += [
    .systemLibrary(
      name: "CXlib", path: "Sources/CXlib",
      providers: [.apt(["libx11-dev", "libxfixes-dev", "libxtst-dev"])]),
    .systemLibrary(
      name: "CGtk4", path: "Sources/CGtk4", pkgConfig: "gtk4",
      providers: [.apt(["libgtk-4-dev"])]),
    // T-RT4: GDK's X11-backend-specific surface API (`<gdk/x11/gdkx.h>`) —
    // a separate module from `CGtk4` (see `Sources/CGdkX11/shim.h`'s doc
    // comment for why) so only `ClipnestGTK`, which actually needs
    // `_NET_WM_WINDOW_TYPE_UTILITY` placement, links libX11 for it.
    .systemLibrary(
      name: "CGdkX11", path: "Sources/CGdkX11", pkgConfig: "gtk4",
      providers: [.apt(["libgtk-4-dev", "libx11-dev"])]),
    // No pkgConfig: ONNX Runtime is NOT in Ubuntu's default repositories, so
    // it is vendored by the .deb rather than resolved from the distro. This is
    // the documented exception to the "system libraries only" dependency rule.
    .systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime"),
    .target(
      name: "ClipnestPlatformLinux",
      dependencies: ["ClipnestCore", "ClipnestSQLite", "CXlib"]),
    // OCR is a SEPARATE target because ONNX Runtime is not in Ubuntu's
    // repositories and must be vendored — mirroring the packaging split, where
    // clipnest-ocr is its own .deb that `clipnest` only Recommends. Everything
    // else builds on a stock Ubuntu box with apt dependencies alone.
    //
    // No compile-time flag gates this target. An earlier design used a
    // `CLIPNEST_HAS_ONNXRUNTIME` flag (see D66 in .claude/project-context.md)
    // because `import COnnxRuntime` textually appearing anywhere hard-errored
    // the build the moment the real `onnxruntime_c_api.h` header was
    // unreachable — `canImport` cannot express "module declared but headers
    // absent." That no longer applies: `Sources/COnnxRuntime/shim.h` is now a
    // fully self-contained, hand-derived OrtApi/OrtApiBase declaration that
    // never includes the real header, so `import COnnxRuntime` always
    // resolves and this target's OCR code is unconditionally compiled in.
    // Whether OCR actually does anything is decided at RUNTIME instead, by
    // `OrtRuntimeAvailability.isAvailable` (a `dlopen` check for
    // `libonnxruntime.so.1` — see `Sources/ClipnestLinuxOCR/Runtime/
    // OrtLibrary.swift`), which is `false` until `clipnest-ocr` is installed.
    .target(
      name: "ClipnestLinuxOCR", dependencies: ["ClipnestCore", "COnnxRuntime"]),
    .target(name: "ClipnestGTK", dependencies: ["ClipnestViewModels", "CGtk4", "CGdkX11"]),
    // The app is split into a LIBRARY plus a thin executable because an
    // executable target's module cannot be `@testable import`ed — SwiftPM
    // reports "is the main module of an executable, and cannot be imported by
    // tests". All orchestration lives in the Kit; main.swift is an 8-line shim.
    .target(
      name: "ClipnestLinuxAppKit",
      dependencies: [
        "ClipnestCore", "ClipnestSQLite", "ClipnestViewModels",
        "ClipnestPlatformLinux", "ClipnestGTK", "ClipnestLinuxOCR", "CXlib",
      ]),
    .executableTarget(name: "ClipnestLinuxApp", dependencies: ["ClipnestLinuxAppKit"]),
    .testTarget(
      name: "ClipnestPlatformLinuxTests",
      dependencies: [
        "ClipnestPlatformLinux", "ClipnestLinuxOCR", "ClipnestGTK",
        "ClipnestLinuxAppKit", "ClipnestCore",
      ]),
  ]
#endif
