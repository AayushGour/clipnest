import Foundation
import Testing

@testable import ClipnestCore

@Suite("BlobStore")
struct BlobStoreTests {

  /// A fresh, throwaway temp directory per test — never the real
  /// `~/Library/Application Support`, per coding-standards.md's testing rules.
  private func makeTempBaseDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "BlobStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("Round-trip write then read returns identical bytes")
  func writeReadRoundTrip() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    let payload = Data("hello blob".utf8)

    let blobPath = try store.write(payload)
    let readBack = try store.read(blobPath: blobPath)

    #expect(readBack == payload)
  }

  @Test("write returns a relative blobPath rooted at 'blobs/'")
  func writeReturnsRelativePath() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    let blobPath = try store.write(Data("relative path check".utf8))

    #expect(blobPath.hasPrefix("\(BlobStore.blobsDirectoryName)/"))
  }

  @Test("Writing identical bytes twice results in exactly one file on disk")
  func identicalWritesDedupToOneFile() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    let payload = Data("same bytes, written twice".utf8)

    let firstPath = try store.write(payload)
    let secondPath = try store.write(payload)

    #expect(firstPath == secondPath)
    let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
    let contents = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
    #expect(contents.count == 1)
  }

  @Test("Writing different bytes creates two separate files")
  func differentWritesCreateSeparateFiles() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    let firstPath = try store.write(Data("content A".utf8))
    let secondPath = try store.write(Data("content B".utf8))

    #expect(firstPath != secondPath)
    let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
    let contents = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
    #expect(contents.count == 2)
  }

  @Test("delete removes the file from disk")
  func deleteRemovesFile() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    let blobPath = try store.write(Data("to be deleted".utf8))

    try store.delete(blobPath: blobPath)

    #expect(throws: BlobStoreError.notFound) {
      try store.read(blobPath: blobPath)
    }
  }

  @Test("Reading a nonexistent blob path throws .notFound")
  func readMissingThrows() {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    #expect(throws: BlobStoreError.notFound) {
      try store.read(blobPath: "\(BlobStore.blobsDirectoryName)/does-not-exist")
    }
  }

  @Test("Deleting a nonexistent blob path is a no-op, not an error (idempotent cleanup)")
  func deleteMissingIsIdempotent() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)

    try store.delete(blobPath: "\(BlobStore.blobsDirectoryName)/does-not-exist")
  }

  @Test("T-PF4: mapped read (.mappedIfSafe) round-trips a large binary payload byte-for-byte")
  func mappedReadRoundTripsLargeBinaryPayloadExactly() throws {
    let baseDirectory = makeTempBaseDirectory()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let store = BlobStore(baseDirectory: baseDirectory)
    // Large enough (~2MB) to exercise real multi-page mapped I/O, and
    // pseudo-random (not repetitive) so a partially-wrong mapped read
    // couldn't accidentally still compare equal.
    var generator = SystemRandomNumberGenerator()
    let payload = Data(
      (0..<2_000_003).map { _ in UInt8.random(in: .min ... .max, using: &generator) })

    let blobPath = try store.write(payload)
    let readBack = try store.read(blobPath: blobPath)

    #expect(readBack.count == payload.count)
    #expect(readBack == payload)
  }

  @Test("contentHash(of:) is stable for identical bytes and differs for different bytes")
  func contentHashStableAndDistinct() {
    let dataA1 = Data("payload A".utf8)
    let dataA2 = Data("payload A".utf8)
    let dataB = Data("payload B".utf8)

    #expect(BlobStore.contentHash(of: dataA1) == BlobStore.contentHash(of: dataA2))
    #expect(BlobStore.contentHash(of: dataA1) != BlobStore.contentHash(of: dataB))
  }

  // MARK: - T-PF8: defaultBaseDirectory's CLIPNEST_TEST_DATA_ROOT override
  //
  // These exercise `defaultBaseDirectory(fileManager:environment:)`'s pure
  // path-resolution logic via the injectable `environment` parameter —
  // never the real process environment (see `ProductionStoreIsolationTests`
  // for the end-to-end proof that the actual production factory methods,
  // unmodified, honor a REAL process environment variable of this name).
  // What a test at this level can prove: the override, when present and
  // non-empty, always wins and always resolves somewhere other than the
  // real production directory; what it can NOT prove on its own: that
  // `xcodebuild test`'s hosted test-host process actually receives the
  // variable — that is proven separately by the T-PF8 handoff's before/after
  // `ClipItems.store` mtime check against a real `xcodebuild test` run.
  //
  // T-SEC1: `defaultBaseDirectoryHonorsOverride` and
  // `defaultBaseDirectoryOverrideNeverAliasesProductionPath` below assert
  // that a non-empty override IS honored — a claim that's only true in a
  // Debug build now that `defaultBaseDirectory`'s override branch is `#if
  // DEBUG`-gated (see that method's doc comment). `#if DEBUG`-gating these
  // two tests themselves keeps the suite honest in both configurations:
  // `swift test` (Debug, the standard/CI command per coding-standards.md)
  // still runs and passes them exactly as before, while a `swift test -c
  // release` run — verified empirically as part of the T-SEC1 fix; see the
  // handoff for the real command output — no longer sees them fail for a
  // reason that's actually the security fix working as intended, not a
  // regression. `defaultBaseDirectoryOverrideIsCompiledOutInReleaseBuilds`
  // below is this suite's Release-side counterpart proving the opposite
  // direction.

  @Test("defaultBaseDirectory with no override resolves to the real production path")
  func defaultBaseDirectoryWithNoOverrideResolvesToProductionPath() {
    let resolved = BlobStore.defaultBaseDirectory(environment: [:])

    let expectedAppSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    #expect(resolved == expectedAppSupport?.appendingPathComponent("Clipnest", isDirectory: true))
  }

  #if DEBUG
    @Test("defaultBaseDirectory honors a non-empty CLIPNEST_TEST_DATA_ROOT override")
    func defaultBaseDirectoryHonorsOverride() {
      let overridePath = "/tmp/BlobStoreTests-override-\(UUID().uuidString)"

      let resolved = BlobStore.defaultBaseDirectory(environment: [
        BlobStore.testDataRootEnvironmentVariableName: overridePath
      ])

      #expect(resolved.path == overridePath)
    }

    @Test(
      "defaultBaseDirectory's override never resolves inside the real production directory (isolation proof)"
    )
    func defaultBaseDirectoryOverrideNeverAliasesProductionPath() {
      let productionPath = BlobStore.defaultBaseDirectory(environment: [:])
      let overridden = BlobStore.defaultBaseDirectory(environment: [
        BlobStore.testDataRootEnvironmentVariableName: "/tmp/BlobStoreTests-isolation-proof"
      ])

      #expect(overridden != productionPath)
      #expect(!overridden.path.hasPrefix(productionPath.path))
    }
  #endif

  @Test(
    "defaultBaseDirectory treats an empty-string override as absent, falling back to production")
  func defaultBaseDirectoryTreatsEmptyOverrideAsAbsent() {
    let withEmptyOverride = BlobStore.defaultBaseDirectory(environment: [
      BlobStore.testDataRootEnvironmentVariableName: ""
    ])
    let withNoOverride = BlobStore.defaultBaseDirectory(environment: [:])

    #expect(withEmptyOverride == withNoOverride)
  }

  // MARK: - T-SEC1: the override is compiled out entirely in Release builds

  #if !DEBUG
    // This test only EXISTS in a non-Debug (Release) compile — under the
    // normal `swift test` (Debug by default), it is not even compiled in,
    // so it never affects the Debug baseline test count. It exists purely
    // to be run via `swift test -c release`, which builds both
    // `ClipnestCore` AND this test target without the `DEBUG` compilation
    // condition — the exact same condition a real notarized Release build
    // ships under. If it runs and passes, that's direct proof (not an
    // assumption) that `defaultBaseDirectory`'s `#if DEBUG` gate actually
    // compiled the override branch out of THIS binary.
    @Test(
      "T-SEC1: in a Release build, CLIPNEST_TEST_DATA_ROOT has zero effect — defaultBaseDirectory always resolves to the real production path"
    )
    func defaultBaseDirectoryOverrideIsCompiledOutInReleaseBuilds() {
      let overridePath = "/tmp/BlobStoreTests-release-inert-\(UUID().uuidString)"

      let resolvedWithOverride = BlobStore.defaultBaseDirectory(environment: [
        BlobStore.testDataRootEnvironmentVariableName: overridePath
      ])
      let resolvedWithNoOverride = BlobStore.defaultBaseDirectory(environment: [:])

      // Same result whether or not the variable is present — the branch
      // that would have read it doesn't exist in this build.
      #expect(resolvedWithOverride == resolvedWithNoOverride)
      #expect(resolvedWithOverride.path != overridePath)
    }
  #endif
}
