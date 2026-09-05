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
  ]
)
