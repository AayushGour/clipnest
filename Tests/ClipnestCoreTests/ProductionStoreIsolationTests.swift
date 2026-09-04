import Foundation
import SwiftData
import Testing

@testable import ClipnestCore

/// T-PF8 (P0 safety fix): proves the actual, UNMODIFIED production factory
/// methods — `BlobStore.defaultBaseDirectory()`, `SwiftDataClipStore
/// .makeProductionContainer()`, `SwiftDataSnippetStore
/// .makeProductionContainer()` — honor the `CLIPNEST_TEST_DATA_ROOT`
/// override end-to-end, not just `defaultBaseDirectory(environment:)`'s pure
/// resolution logic in isolation (see `BlobStoreTests`'s narrower override
/// tests for that half).
///
/// Deliberately mutates the REAL process environment (`setenv`/`unsetenv`)
/// for the span of each test — that's what a real launch of the app process
/// actually looks like (an env var set ON the process, not an injected
/// dictionary), and it's the only way to exercise `makeProductionContainer()`,
/// which calls `BlobStore.defaultBaseDirectory()` with no arguments (i.e.
/// reads `ProcessInfo.processInfo.environment` for real, exactly like
/// production `AppEnvironment.init` does).
///
/// `.serialized` — matching `SwiftDataClipStoreTests`/
/// `SwiftDataSnippetStoreTests`'s identical precedent for a different
/// process-global hazard — so this suite's env-var mutation can never
/// interleave with another concurrently-running test under Swift Testing's
/// default parallel execution.
///
/// WHAT THIS DOES NOT PROVE: that `xcodebuild test`'s *hosted* test-host
/// process (`ClipnestAppTests`, per `ClipnestApp/project.yml`'s `TEST_HOST`)
/// actually receives `CLIPNEST_TEST_DATA_ROOT` from that scheme's
/// `test.environmentVariables`. No test running inside `swift test` can
/// prove that — it's a completely different process/build graph than
/// `xcodebuild test`'s hosted `ClipnestAppTests` target. That half is proven
/// empirically, once, via the T-PF8 handoff's before/after
/// `~/Library/Application Support/Clipnest/ClipItems.store` mtime check
/// against a real `xcodebuild test` run. What THIS suite proves: assuming
/// the variable does reach the process (which that separate check confirms),
/// the production code that reads it redirects every on-disk write away
/// from the real store — including the SwiftData containers, not just
/// `BlobStore`.
///
/// T-SEC1: every test below asserts that a real process env var IS honored
/// end-to-end — a claim that's only true in a Debug build now that
/// `BlobStore.defaultBaseDirectory`'s override branch is `#if DEBUG`-gated
/// (see that method's doc comment — the fix that stops a notarized Release
/// build from ever honoring this variable). This whole file is therefore
/// `#if DEBUG`-gated too: `swift test` (Debug, the standard/CI command)
/// still runs and passes it exactly as before, while a `swift test -c
/// release` run no longer sees it fail for a reason that's actually the
/// security fix working as intended, not a regression — verified
/// empirically as part of the T-SEC1 fix (see that task's handoff for the
/// real command output).
#if DEBUG
  @Suite("Production store isolation (T-PF8)", .serialized)
  struct ProductionStoreIsolationTests {

    private func makeThrowawayOverrideDirectory() -> URL {
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "ProductionStoreIsolationTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func realProductionDirectory() -> URL {
      BlobStore.defaultBaseDirectory(environment: [:])
    }

    private func modificationDate(of url: URL) -> Date? {
      (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @Test(
      "BlobStore.defaultBaseDirectory(), called exactly as production callers call it, honors a real CLIPNEST_TEST_DATA_ROOT process env var"
    )
    func blobStoreDefaultBaseDirectoryHonorsRealProcessEnvVar() {
      let overrideDirectory = makeThrowawayOverrideDirectory()
      defer {
        unsetenv(BlobStore.testDataRootEnvironmentVariableName)
        try? FileManager.default.removeItem(at: overrideDirectory)
      }
      setenv(BlobStore.testDataRootEnvironmentVariableName, overrideDirectory.path, 1)

      // No `environment:` argument — exercises the exact same call production
      // code (`AppEnvironment.init`, both stores' `makeProductionContainer()`)
      // makes, which reads the real process environment.
      let resolved = BlobStore.defaultBaseDirectory()

      #expect(resolved.path == overrideDirectory.path)
      #expect(resolved != realProductionDirectory())
    }

    @Test(
      "SwiftDataClipStore.makeProductionContainer() honors a real CLIPNEST_TEST_DATA_ROOT env var and never touches the real ClipItems.store"
    )
    func swiftDataClipStoreProductionContainerHonorsOverride() throws {
      let overrideDirectory = makeThrowawayOverrideDirectory()
      defer {
        unsetenv(BlobStore.testDataRootEnvironmentVariableName)
        try? FileManager.default.removeItem(at: overrideDirectory)
      }
      setenv(BlobStore.testDataRootEnvironmentVariableName, overrideDirectory.path, 1)

      let realStoreFile = realProductionDirectory().appendingPathComponent("ClipItems.store")
      let realStoreMTimeBefore = modificationDate(of: realStoreFile)

      _ = try SwiftDataClipStore.makeProductionContainer()

      let expectedStoreFile = overrideDirectory.appendingPathComponent("ClipItems.store")
      #expect(FileManager.default.fileExists(atPath: expectedStoreFile.path))
      #expect(modificationDate(of: realStoreFile) == realStoreMTimeBefore)
    }

    @Test(
      "SwiftDataSnippetStore.makeProductionContainer() honors a real CLIPNEST_TEST_DATA_ROOT env var and never touches the real Snippets.store"
    )
    func swiftDataSnippetStoreProductionContainerHonorsOverride() throws {
      let overrideDirectory = makeThrowawayOverrideDirectory()
      defer {
        unsetenv(BlobStore.testDataRootEnvironmentVariableName)
        try? FileManager.default.removeItem(at: overrideDirectory)
      }
      setenv(BlobStore.testDataRootEnvironmentVariableName, overrideDirectory.path, 1)

      let realStoreFile = realProductionDirectory().appendingPathComponent("Snippets.store")
      let realStoreMTimeBefore = modificationDate(of: realStoreFile)

      _ = try SwiftDataSnippetStore.makeProductionContainer()

      let expectedStoreFile = overrideDirectory.appendingPathComponent("Snippets.store")
      #expect(FileManager.default.fileExists(atPath: expectedStoreFile.path))
      #expect(modificationDate(of: realStoreFile) == realStoreMTimeBefore)
    }
  }
#endif
