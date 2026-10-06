// ClipnestSQLite
//
// The Linux persistence backend: `ClipStore` and `SnippetStore` implemented
// over SQLite, behind the exact protocols `SwiftDataClipStore` and
// `SwiftDataSnippetStore` satisfy on macOS.
//
// Builds on macOS as well as Linux so the shared contract suites in
// `ClipnestCoreTests` can validate it on the existing CI runner.
