// swift-tools-version: 6.0
//
// T-GLY1 spike tooling — NOT part of the shipping app.
//
// Deliberately a separate, standalone SPM package rooted at
// `tools/glyph-classifier/`, never referenced by the repo-root
// `Package.swift` (ClipnestCore) or by `ClipnestApp/project.yml`. Two
// reasons this separation matters, not just tidiness:
//   1. `GlyphTrainer` links `CreateML`, a training-time-only framework that
//      must never end up linked into the shipping app binary (coding-
//      standards.md dependency policy: system frameworks only, and even
//      among those, CreateML is explicitly a build/tooling dependency, not
//      a runtime one — see this package's README-equivalent comment in
//      `Sources/GlyphTrainer/main.swift`).
//   2. Keeping this out of the root package means `swift build`/`swift
//      test` at the repo root (ClipnestCore's CI-facing contract, coding-
//      standards.md) never touches CreateML, AppKit-heavy rendering code,
//      or the multi-thousand-image dataset this generates — none of that
//      is safe or desirable to build as part of the app's own test suite.
//
// Two executables, kept in separate targets so dataset generation (AppKit/
// CoreText/CoreGraphics only) never needs to link CreateML at all:
//   - `GlyphDatasetGen` — renders the synthetic training/test image set.
//   - `GlyphTrainer`    — trains an `MLImageClassifier` against that set
//     and evaluates it (held-out synthetic split + real screenshot crops).
// `GlyphClassifierSupport` is the shared, framework-light catalog of
// classes (keyboard glyphs, the emoji subset, confusable characters) both
// executables need — kept in one place per coding-standards.md's DRY rule
// rather than duplicated between the two mains.
import PackageDescription

let package = Package(
  name: "GlyphClassifierTools",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "GlyphClassifierSupport"),
    .executableTarget(
      name: "GlyphDatasetGen",
      dependencies: ["GlyphClassifierSupport"]
    ),
    .executableTarget(
      name: "GlyphTrainer",
      dependencies: ["GlyphClassifierSupport"]
    ),
    // `MetricsReport`'s pure gate-evaluation logic (no CreateML/training
    // dependency) is unit-tested here via a plain `swift test` — run from
    // `tools/glyph-classifier/`, separate from the root repo's `swift
    // test` (which never touches this package at all, see this file's
    // header comment).
    .testTarget(
      name: "GlyphClassifierSupportTests",
      dependencies: ["GlyphClassifierSupport"]
    ),
  ]
)
