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
