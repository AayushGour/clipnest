// ClipnestCore
//
// The fully unit-testable core of Clipnest, a native macOS clipboard manager.
// This module has no UI — it holds the clipboard-monitoring, privacy-filtering,
// and persistence logic exercised entirely through `swift test`.
//
// See `docs/superpowers/specs/2026-08-06-clipnest-design.md` for the design and
// `docs/superpowers/plans/2026-08-06-clipnest-plan.md` for the task breakdown.

/// The current `ClipnestCore` package version. Bumped manually alongside releases;
/// exists so the target has a source file even before other types land, and gives
/// callers a simple way to confirm which core version they linked against.
public let clipnestCoreVersion = "0.1.0"
