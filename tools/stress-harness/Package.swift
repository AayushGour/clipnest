// swift-tools-version: 6.0
//
// T-STRESS1 — standalone stress/soak harness for the capture -> OCR -> paste
// pipeline. Deliberately a separate, standalone SPM package rooted at
// `tools/stress-harness/`, never referenced by the repo-root `Package.swift`
// (ClipnestCore) or by `ClipnestApp/project.yml` — same isolation precedent
// as `tools/glyph-classifier/` (see that package's own header comment).
//
// Depends on the real `ClipnestCore` library via a local path dependency so
// every scenario drives the actual production types (`ClipboardMonitor`,
// `PasteboardReader`, `SwiftDataClipStore`, `BlobStore`,
// `VisionTextRecognizer`, `Paster`) — never reimplementations. `swift build`/
// `swift test` at the repo root never touches this package, and this
// package's own build never affects the root package's resolution.
import PackageDescription

let package = Package(
  name: "StressHarness",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "ClipnestCore", path: "../../")
  ],
  targets: [
    .executableTarget(
      name: "StressHarness",
      dependencies: [
        .product(name: "ClipnestCore", package: "ClipnestCore")
      ]
    )
  ]
)
