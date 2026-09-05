import AppKit
import Foundation
import Testing

@testable import ClipnestCore

/// A fake pasteboard that also fakes `changeCount`, so `ClipboardMonitor` can be
/// driven deterministically via `checkNow()` — no real `NSPasteboard`, no real
/// `Timer`, per coding-standards.md's testing rules.
private final class FakeMonitoredPasteboard: MonitoredPasteboard, @unchecked Sendable {
  var availableTypes: [NSPasteboard.PasteboardType]
  var strings: [NSPasteboard.PasteboardType: String]
  var datas: [NSPasteboard.PasteboardType: Data]
  var changeCount: Int

  init(
    changeCount: Int = 0,
    availableTypes: [NSPasteboard.PasteboardType] = [],
    strings: [NSPasteboard.PasteboardType: String] = [:],
    datas: [NSPasteboard.PasteboardType: Data] = [:]
  ) {
    self.changeCount = changeCount
    self.availableTypes = availableTypes
    self.strings = strings
    self.datas = datas
  }

  func string(forType type: NSPasteboard.PasteboardType) -> String? {
    strings[type]
  }

  func data(forType type: NSPasteboard.PasteboardType) -> Data? {
    datas[type]
  }

  /// Simulates a user copy: new content, incremented change count.
  func simulateCopy(text: String) {
    strings = [.string: text]
    datas = [:]
    availableTypes = [.string]
    changeCount += 1
  }

  func simulateConcealedCopy() {
    availableTypes = [.string, PrivacyFilter.concealedPasteboardType]
    strings = [.string: "super-secret-password"]
    datas = [:]
    changeCount += 1
  }

  /// Simulates copying an image (e.g. from Preview): only image bytes, no
  /// `.string` representation. `type` defaults to `.png` (matching
  /// `PasteboardReader.imagePasteboardTypes`'s T-PF2 priority order); pass
  /// `.tiff` to simulate a source app that only offers the TIFF
  /// representation.
  func simulateImageCopy(data: Data, type: NSPasteboard.PasteboardType = .png) {
    strings = [:]
    datas = [type: data]
    availableTypes = [type]
    changeCount += 1
  }

  /// Simulates copying a Finder file reference.
  func simulateFileCopy(url: URL) {
    strings = [.fileURL: url.absoluteString]
    datas = [:]
    availableTypes = [.fileURL]
    changeCount += 1
  }
}

private struct FakeFrontmostApplicationProvider: FrontmostApplicationProviding {
  var frontmostBundleID: String?
  var frontmostAppName: String?
}

/// A `ClipStore` whose `insertOrBumpDuplicate` always fails, so tests can prove
/// `ClipboardMonitor` surfaces the failure instead of silently swallowing it.
private actor ThrowingClipStore: ClipStore {
  func insertOrBumpDuplicate(_ item: ClipItem) async throws -> ClipItem {
    throw ClipStoreError.ioFailure(underlying: "simulated disk failure")
  }

  func fetchAll() async throws -> [ClipItem] { [] }
  func fetchPinned() async throws -> [ClipItem] { [] }
  func query(
    text: String, kind: ItemKind?, scope: ClipScope, offset: Int, limit: Int
  ) async throws -> [ClipItem] { [] }
  func setPinned(_ id: UUID, pinned: Bool) async throws { throw ClipStoreError.notFound }
  func setRecognizedText(_ id: UUID, text: String) async throws { throw ClipStoreError.notFound }
  func fetchImagesNeedingRecognition() async throws -> [ClipItem] { [] }
  func delete(_ id: UUID) async throws { throw ClipStoreError.notFound }
  func clearHistory() async throws {}
  func enforceRetention(cap: RetentionCap?) async throws {}
}

/// Records the last error handed to a `CaptureFailureHandler`. A plain class
/// (not an actor) is fine here: `checkNow()` calls the handler synchronously
/// within its own async body, so by the time `await monitor.checkNow()`
/// returns, `reportedError` has already been set — there's no concurrent
/// access to race. `@unchecked Sendable` reflects that test-only guarantee.
private final class CaptureFailureRecorder: @unchecked Sendable {
  private(set) var reportedError: Error?

  func handle(_ error: Error) {
    reportedError = error
  }
}

/// A single mutable value box, so a test's provider closure (e.g.
/// `captureEnabledProvider`, `textRecognitionEnabledProvider`,
/// `textRecognitionQualityProvider`) can read a value that the test body
/// flips mid-test. Same "plain wrapper is fine" reasoning as
/// `CaptureFailureRecorder`/`CaptureRecorder` below: only ever touched
/// sequentially from this @MainActor test body, never concurrently. Avoids
/// capturing a raw `var` directly in a `@Sendable` closure, which Swift 6
/// strict concurrency flags even though the access here is provably
/// sequential. Generic (not `Bool`-only) so `TextRecognitionQuality`'s
/// T-OCR8 mid-session test (below) reuses it instead of a second
/// copy-pasted box type — DRY per coding-standards.md.
private final class MutableBox<Value: Sendable>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// Records every `ClipItem` handed to `ClipboardMonitor.onCapture` (T51).
/// Same "plain class is fine" reasoning as `CaptureFailureRecorder` above:
/// `checkNow()` invokes `onCapture` synchronously within its own async body
/// (`@MainActor`, same actor this test suite itself runs on), so by the
/// time `await monitor.checkNow()` returns, `capturedItems` already
/// reflects it — no concurrent access to race.
private final class CaptureRecorder: @unchecked Sendable {
  private(set) var capturedItems: [ClipItem] = []

  func record(_ item: ClipItem) {
    capturedItems.append(item)
  }
}

/// A `TextRecognizing` fake for T-OCR2's `ClipboardMonitor` wiring tests —
/// records every image it was asked to recognize (so tests can assert
/// whether/how-many-times it ran) and returns a canned result. An `actor`
/// (not a plain class): unlike `CaptureFailureRecorder`/`CaptureRecorder`
/// above (whose state is only ever touched synchronously, inside
/// `checkNow()`'s own call), `recognizeText(in:)` runs off `checkNow()`'s
/// call stack entirely — inside `ClipboardMonitor`'s detached OCR task, see
/// `scheduleTextRecognition`'s doc comment — so its state genuinely can be
/// read from the test body while a recognition call is still in flight;
/// actor isolation is what makes that safe rather than a documented
/// "sequential access only" convention.
private actor FakeTextRecognizer: TextRecognizing {
  private(set) var recognizedImages: [Data] = []
  /// T-OCR8: the `quality` argument each `recognizeText(in:quality:)` call
  /// actually received, in call order — lets a test assert the *requested*
  /// quality reached the recognizer (i.e. `ClipboardMonitor`'s
  /// `textRecognitionQualityProvider` wiring) without depending on real
  /// Vision at all, mirroring `recognizedImages`' existing role for the
  /// image argument.
  private(set) var recognizedQualities: [TextRecognitionQuality] = []
  private let result: String?
  private let isGated: Bool
  /// FIFO queue of continuations currently suspended inside
  /// `recognizeText(in:)` because this recognizer was constructed with
  /// `gated: true`. A single-continuation box isn't enough for T-OCR3's
  /// "two rapid copies before the first Vision pass completes" adversarial
  /// case — two concurrent `recognizeText(in:)` calls both suspend at
  /// once, so a lone `var gate` would silently drop/leak the first
  /// continuation when the second call overwrote it. A queue lets
  /// `release()` resolve exactly one waiter at a time, oldest first,
  /// deterministically, and `pendingGateCount` lets a test prove both
  /// calls are genuinely in flight simultaneously before releasing either.
  private var gates: [CheckedContinuation<Void, Never>] = []

  /// - Parameters:
  ///   - result: what every `recognizeText(in:)` call returns.
  ///   - gated: when `true`, `recognizeText(in:)` suspends until `release()`
  ///     is called — lets the "recognition is non-blocking" test prove
  ///     `checkNow()` already returned before recognition finishes, and lets
  ///     the concurrent-duplicate-copy test control exactly when each of
  ///     two simultaneously in-flight calls resolves.
  init(result: String?, gated: Bool = false) {
    self.result = result
    self.isGated = gated
  }

  func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String? {
    recognizedImages.append(imageData)
    recognizedQualities.append(quality)
    if isGated {
      await withCheckedContinuation { continuation in
        gates.append(continuation)
      }
    }
    return result
  }

  /// Releases the single oldest `recognizeText(in:)` call currently
  /// suspended (FIFO) because this recognizer was constructed with
  /// `gated: true`. No-op if nothing is waiting (e.g. called before
  /// `recognizeText` has run yet — the caller is expected to have already
  /// awaited that far).
  func release() {
    guard !gates.isEmpty else { return }
    gates.removeFirst().resume()
  }

  /// Number of `recognizeText(in:)` calls currently suspended, waiting on
  /// `release()`.
  var pendingGateCount: Int { gates.count }
}

/// A `FileManager` that can pause its very next `fileExists(atPath:)` call
/// (blocking the calling thread until released) and records every
/// `removeItem(at:)` call it's asked to perform.
///
/// Built for the T-HANG4 second-`ignoredChangeCount`-check regression tests
/// below: `ClipboardMonitor.checkNow()`'s two `ignoredChangeCount` checks
/// are evaluated against a `currentChangeCount` captured once at the top of
/// the call, so the only way to deterministically hit the SECOND check (not
/// the first, which would already have bailed) is to have a concurrent
/// `ignore(changeCount:)` call land strictly between them. `checkNow()`
/// offers no injection point for that window by design (it's a real race
/// against `Paster`, not something meant to be controllable) — so these
/// tests synchronize on the one seam `BlobStore` already exposes for
/// testability instead: its injectable `fileManager:` initializer
/// parameter (see `BlobStore`'s own doc comment — "tests point it at a
/// throwaway temp directory"). This subclass extends that same idea to the
/// `FileManager` `BlobStore` uses, letting a test pause the SPECIFIC
/// `fileExists(atPath:)` call `write(_:)`'s dedup check makes, with zero
/// changes to `BlobStore.swift` or `ClipboardMonitor.swift`.
///
/// `@unchecked Sendable`: all mutable state is protected by `NSLock`, and
/// the two `DispatchSemaphore`s are safe to signal/wait on from any thread
/// by design — mirroring `BlobStore.fileManager`'s own "documented
/// thread-safety, not language-checked" shape.
private final class GatingFileManager: FileManager, @unchecked Sendable {
  private let lock = NSLock()
  private var deletedFilePaths: [String] = []
  private var armed = false
  private var currentlyPaused = false
  private let releaseGate = DispatchSemaphore(value: 0)

  /// Every path `removeItem(at:)` was asked to delete, in call order. The
  /// T-HANG4 regression assertion reads this to prove a bail deleted
  /// nothing.
  var deletedPaths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return deletedFilePaths
  }

  /// Arms the gate: the very next `fileExists(atPath:)` call blocks the
  /// calling thread (a real, synchronous block — `BlobStore.write(_:)` is
  /// not `async`) until `release()` is called, first flipping `isPaused` to
  /// `true` for the duration. Disarms itself the moment it fires, so it
  /// affects exactly one call.
  func armNextFileExistsCall() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  /// Whether a gated `fileExists(atPath:)` call is currently paused,
  /// waiting on `release()` — i.e. proof that `BlobStore.write(_:)` is
  /// genuinely mid-flight, not yet returned. Polled from `@MainActor` test
  /// code via the file's `waitUntil` helper rather than blocked on
  /// directly: reading a lock-protected `Bool` from the main actor never
  /// risks blocking it, unlike a real semaphore wait would. Only
  /// `fileExists(atPath:)` itself performs the actual blocking wait, and
  /// only on whatever background thread `BlobStore.write(_:)`'s
  /// `Task.detached` runs on.
  var isPaused: Bool {
    lock.lock()
    defer { lock.unlock() }
    return currentlyPaused
  }

  /// Lets a currently-paused `fileExists(atPath:)` call return.
  func release() {
    releaseGate.signal()
  }

  override func fileExists(atPath path: String) -> Bool {
    lock.lock()
    let shouldPause = armed
    if shouldPause { armed = false }
    lock.unlock()
    if shouldPause {
      lock.lock()
      currentlyPaused = true
      lock.unlock()
      releaseGate.wait()
      lock.lock()
      currentlyPaused = false
      lock.unlock()
    }
    return super.fileExists(atPath: path)
  }

  override func removeItem(at url: URL) throws {
    lock.lock()
    deletedFilePaths.append(url.path)
    lock.unlock()
    try super.removeItem(at: url)
  }
}

/// Polls `condition` (bounded by `timeout`) instead of a fixed sleep — the
/// OCR-notification tests below observe state that changes asynchronously,
/// off `checkNow()`'s own call stack (see `FakeTextRecognizer`'s doc
/// comment), so there is no single `await` that resolves the moment
/// recognition/`onCapture` lands. Mirrors `ClipnestAppTests`'s
/// `AsyncWaiting.waitUntil` (not shared across targets/modules, so
/// duplicated here rather than reached into the App test target).
@MainActor
private func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () async -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    await Task.yield()
  }
}

@Suite("ClipboardMonitor")
@MainActor
struct ClipboardMonitorTests {

  @Test("checkNow captures exactly one ClipItem on an accepted change")
  func capturesAcceptedChange() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(
        frontmostBundleID: "com.apple.TextEdit",
        frontmostAppName: "TextEdit"
      )
    )

    pasteboard.simulateCopy(text: "hello clipboard")
    let captured = await monitor.checkNow()

    #expect(captured != nil)
    #expect(captured?.previewText == "hello clipboard")
    #expect(captured?.sourceBundleID == "com.apple.TextEdit")

    let all = try await store.fetchAll()
    #expect(all.count == 1)
  }

  @Test("onCapture fires with the stored item after a successful capture (T51)")
  func onCaptureFiresOnSuccessfulCapture() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
    let recorder = CaptureRecorder()
    monitor.onCapture = { item in recorder.record(item) }

    pasteboard.simulateCopy(text: "hello clipboard")
    let captured = await monitor.checkNow()

    #expect(recorder.capturedItems.count == 1)
    #expect(recorder.capturedItems.first?.id == captured?.id)
    #expect(recorder.capturedItems.first?.previewText == "hello clipboard")
  }

  @Test("onCapture fires again on a dedup bump — the bumped item now sorts to the top again")
  func onCaptureFiresOnDedupBump() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
    let recorder = CaptureRecorder()
    monitor.onCapture = { item in recorder.record(item) }

    pasteboard.simulateCopy(text: "same text")
    _ = await monitor.checkNow()
    pasteboard.simulateCopy(text: "same text")
    _ = await monitor.checkNow()

    #expect(recorder.capturedItems.count == 2)
    #expect(recorder.capturedItems[0].id == recorder.capturedItems[1].id)
  }

  @Test("onCapture does not fire when nothing is captured this cycle")
  func onCaptureDoesNotFireWhenNothingCaptured() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 5)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
    let recorder = CaptureRecorder()
    monitor.onCapture = { item in recorder.record(item) }

    _ = await monitor.checkNow()

    #expect(recorder.capturedItems.isEmpty)
  }

  @Test("checkNow is a no-op when the pasteboard hasn't changed")
  func noOpWhenUnchanged() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 5)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    let result = await monitor.checkNow()

    #expect(result == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("checkNow does not capture content carrying the concealed marker")
  func rejectsConcealedContent() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    pasteboard.simulateConcealedCopy()
    let result = await monitor.checkNow()

    #expect(result == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("While paused, no changes are captured even though the pasteboard changed")
  func pausedMonitorCapturesNothing() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    monitor.pause()
    pasteboard.simulateCopy(text: "should not be captured")
    let result = await monitor.checkNow()

    #expect(result == nil)
    #expect(monitor.isPaused == true)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("resume() allows capture again after pause()")
  func resumeReenablesCapture() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    monitor.pause()
    pasteboard.simulateCopy(text: "captured later")
    _ = await monitor.checkNow()
    monitor.resume()

    pasteboard.simulateCopy(text: "captured now")
    let result = await monitor.checkNow()

    #expect(result?.previewText == "captured now")
    let all = try await store.fetchAll()
    #expect(all.count == 1)
  }

  @Test(
    "ignore(changeCount:) suppresses capture of that self-write, but a later real change is still captured"
  )
  func ignoresOwnPasteboardWrite() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    // Simulate Clipnest's own pasteboard write (e.g. copy-on-select): the
    // change count advances, and the composition root registers that exact
    // change count as self-inflicted before the next checkNow() runs.
    pasteboard.simulateCopy(text: "clipnest self-write")
    monitor.ignore(changeCount: pasteboard.changeCount)
    let ignoredResult = await monitor.checkNow()

    #expect(ignoredResult == nil)
    let afterIgnored = try await store.fetchAll()
    #expect(afterIgnored.isEmpty)

    // A subsequent, real external copy is captured normally — the
    // suppression only ever applies to the one registered changeCount.
    pasteboard.simulateCopy(text: "a real external copy")
    let capturedResult = await monitor.checkNow()

    #expect(capturedResult?.previewText == "a real external copy")
    let afterReal = try await store.fetchAll()
    #expect(afterReal.count == 1)
  }

  @Test(
    "checkNow surfaces a ClipStore failure instead of silently returning an indistinguishable nil")
  func surfacesStoreFailure() async {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = ThrowingClipStore()
    let recorder = CaptureFailureRecorder()
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureFailureHandler: recorder.handle
    )

    pasteboard.simulateCopy(text: "will fail to store")
    let result = await monitor.checkNow()

    #expect(result == nil)
    #expect(
      recorder.reportedError as? ClipStoreError == .ioFailure(underlying: "simulated disk failure"))
  }

  @Test("Consecutive identical copies dedup through the monitor")
  func dedupsThroughMonitor() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    pasteboard.simulateCopy(text: "same content")
    _ = await monitor.checkNow()
    pasteboard.simulateCopy(text: "same content")
    _ = await monitor.checkNow()

    let all = try await store.fetchAll()
    #expect(all.count == 1)
  }

  // MARK: - Image capture via BlobStore (T20)

  private func makeTempBlobStore() -> (store: BlobStore, baseDirectory: URL) {
    let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClipboardMonitorTests-\(UUID().uuidString)", isDirectory: true)
    return (BlobStore(baseDirectory: baseDirectory), baseDirectory)
  }

  /// Same as `makeTempBlobStore()`, but backed by a `GatingFileManager` so
  /// the T-HANG4 second-check bail regression tests below can pause a blob
  /// write mid-flight. See `GatingFileManager`'s doc comment.
  private func makeGatedTempBlobStore() -> (
    store: BlobStore, fileManager: GatingFileManager, baseDirectory: URL
  ) {
    let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ClipboardMonitorTests-gated-\(UUID().uuidString)", isDirectory: true)
    let gatingFileManager = GatingFileManager()
    return (
      BlobStore(baseDirectory: baseDirectory, fileManager: gatingFileManager), gatingFileManager,
      baseDirectory
    )
  }

  @Test("Capturing an image writes its bytes to BlobStore and sets a valid blobPath + byteSize")
  func capturesImageWithBlob() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let imageData = ImageFixtures.makeTinyImageData(width: 3, height: 3)

    pasteboard.simulateImageCopy(data: imageData)
    let captured = await monitor.checkNow()

    #expect(captured?.kind == .image)
    #expect(captured?.byteSize == imageData.count)
    let blobPath = try #require(captured?.blobPath)
    #expect(try blobStore.read(blobPath: blobPath) == imageData)
  }

  @Test("Copying the same image twice reuses a single blob file on disk")
  func duplicateImageCopiesReuseOneBlob() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let imageData = ImageFixtures.makeTinyImageData(width: 5, height: 5)

    pasteboard.simulateImageCopy(data: imageData)
    _ = await monitor.checkNow()
    pasteboard.simulateImageCopy(data: imageData)
    _ = await monitor.checkNow()

    let all = try await store.fetchAll()
    #expect(all.count == 1)

    let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
    let contents = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
    #expect(contents.count == 1)
  }

  // MARK: - T-HANG4: second ignoredChangeCount check's blob-safety bail path
  //
  // Regression coverage for the P0 data-loss bug the reviewer flagged as
  // having zero test coverage: `checkNow()`'s SECOND `ignoredChangeCount`
  // check (added for T-HANG4 — see `ClipboardMonitor.swift`'s doc comment
  // on `ignoredChangeCount`) used to call `blobStore.delete(blobPath:)` on
  // its bail path. Since `BlobStore` is content-addressed with no
  // reference counting, `write(_:)` returns an EXISTING file's path
  // whenever those exact bytes are already on disk — the bail fires on a
  // self-paste race where the bytes are, by construction, an existing
  // history item's own content round-tripped through the pasteboard, so
  // that delete call very often deleted a blob a different, still-visible
  // item was the sole referrer of, corrupting it. senior-dev removed the
  // delete call from `ClipboardMonitor.swift`; the tests below prove it
  // stays removed (1) and that removing it didn't trade that bug for a new
  // "legitimate capture gets dropped" one (2), plus one more sanity check
  // that the match is exact, not a blanket suppression (3).

  @Test(
    "T-HANG4 regression: when the second ignoredChangeCount check bails, no blob is deleted — a blob an existing item still references survives byte-for-byte"
  )
  func secondCheckBailDeletesNoBlobs() async throws {
    let (blobStore, gatingFileManager, baseDirectory) = makeGatedTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let imageData = ImageFixtures.makeTinyImageData(width: 7, height: 7)

    // Establish a real, live, on-disk item first — content X, an ordinary
    // ungated write.
    pasteboard.simulateImageCopy(data: imageData)
    let existing = try #require(await monitor.checkNow())
    let existingBlobPath = try #require(existing.blobPath)

    // The self-paste race: the SAME bytes arrive again (exactly why the
    // write below is a dedup hit against `existingBlobPath`, not a fresh
    // file — see this section's doc comment). Arm the gate so
    // `write(_:)`'s dedup `fileExists` check pauses mid-flight, giving this
    // test a deterministic window to land `ignore(changeCount:)` strictly
    // between `checkNow()`'s first (already-passed, since
    // `ignoredChangeCount` is still nil at that point) and second
    // `ignoredChangeCount` checks — i.e. guarantees the SECOND check, not
    // the first, is the one that bails.
    gatingFileManager.armNextFileExistsCall()
    pasteboard.simulateImageCopy(data: imageData)
    let racingChangeCount = pasteboard.changeCount

    let checkTask = Task { @MainActor in
      await monitor.checkNow()
    }
    // Poll (never block the main actor) until `write(_:)`'s gated
    // `fileExists` call has genuinely paused — proof `checkNow()` is
    // mid-flight past its first check, not yet at its second.
    await waitUntil { gatingFileManager.isPaused }
    try #require(gatingFileManager.isPaused)
    monitor.ignore(changeCount: racingChangeCount)
    gatingFileManager.release()

    let bailedResult = await checkTask.value
    #expect(bailedResult == nil)

    // The regression assertion: zero deletes, on any path, for this bail.
    #expect(gatingFileManager.deletedPaths.isEmpty)
    // The concrete consequence that matters: the EXISTING item's blob is
    // still there, byte-identical — not corrupted by a delete that used to
    // fire right here.
    #expect(try blobStore.read(blobPath: existingBlobPath) == imageData)
    // Nothing new was persisted for the bailed cycle.
    let all = try await store.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.id == existing.id)
  }

  @Test(
    "A legitimate external copy arriving right after a second-check bail is still captured on the very next cycle — the bail does not wedge the monitor or drop the following capture"
  )
  func secondCheckBailDoesNotDropSubsequentLegitimateCapture() async throws {
    let (blobStore, gatingFileManager, baseDirectory) = makeGatedTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let imageData = ImageFixtures.makeTinyImageData(width: 9, height: 9)

    // Same race setup as `secondCheckBailDeletesNoBlobs` above — see that
    // test for the full choreography explanation.
    pasteboard.simulateImageCopy(data: imageData)
    let existing = try #require(await monitor.checkNow())

    gatingFileManager.armNextFileExistsCall()
    pasteboard.simulateImageCopy(data: imageData)
    let racingChangeCount = pasteboard.changeCount

    let checkTask = Task { @MainActor in
      await monitor.checkNow()
    }
    // Same choreography as `secondCheckBailDeletesNoBlobs` above — see that
    // test for the full explanation.
    await waitUntil { gatingFileManager.isPaused }
    try #require(gatingFileManager.isPaused)
    monitor.ignore(changeCount: racingChangeCount)
    gatingFileManager.release()

    let bailedResult = await checkTask.value
    #expect(bailedResult == nil)

    // This is the property that matters most: trading a rare duplicate row
    // for a rare LOST clipboard entry would be a strictly worse bug than
    // the one being fixed. A genuinely different, external copy arriving
    // right after the bail must still be captured normally on the next
    // cycle — the bail must not leave `ignoredChangeCount` (or anything
    // else) in a state that swallows unrelated future captures.
    pasteboard.simulateCopy(text: "a real external copy, not a self-write")
    let captured = await monitor.checkNow()

    #expect(captured?.previewText == "a real external copy, not a self-write")
    let all = try await store.fetchAll()
    #expect(all.count == 2)
    #expect(all.contains(where: { $0.id == existing.id }))
    #expect(all.contains(where: { $0.id == captured?.id }))
  }

  @Test(
    "A stale/mismatched ignoredChangeCount never bails a different cycle's capture — the check is an exact match, not a blanket suppression"
  )
  func mismatchedIgnoredChangeCountNeverBails() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    // Registers an ignored changeCount that will never actually be the
    // pasteboard's current changeCount below — simulating a stale/unrelated
    // self-write registration (see `ignoredChangeCount`'s "only one
    // tracked at a time" doc comment).
    monitor.ignore(changeCount: 999)

    pasteboard.simulateCopy(text: "genuinely external copy")
    let captured = await monitor.checkNow()

    #expect(captured?.previewText == "genuinely external copy")
    let all = try await store.fetchAll()
    #expect(all.count == 1)
  }

  // MARK: - T-PF2: PNG-preferred capture + capture-time ceilings, full pipeline

  @Test(
    "A TIFF-only image copy still writes its bytes to BlobStore, unaffected by the PNG-first change"
  )
  func capturesTIFFOnlyImageWithBlob() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let tiffData = ImageFixtures.makeTinyImageData(width: 3, height: 3, format: .tiff)

    pasteboard.simulateImageCopy(data: tiffData, type: .tiff)
    let captured = await monitor.checkNow()

    #expect(captured?.kind == .image)
    #expect(captured?.byteSize == tiffData.count)
    let blobPath = try #require(captured?.blobPath)
    #expect(try blobStore.read(blobPath: blobPath) == tiffData)
  }

  @Test(
    "An over-byte-ceiling image capture is rejected cleanly: nothing stored, no blob written, no crash"
  )
  func rejectsOverByteCeilingImageCaptureCleanly() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let oversized = Data(count: PasteboardReader.maxCapturedImageByteSize + 1)

    pasteboard.simulateImageCopy(data: oversized)
    let captured = await monitor.checkNow()

    #expect(captured == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
    // No blob directory should even be created — the write path is never
    // reached for a rejected capture (no partial write).
    let blobsDirectory = baseDirectory.appendingPathComponent(BlobStore.blobsDirectoryName)
    #expect(!FileManager.default.fileExists(atPath: blobsDirectory.path))
  }

  @Test(
    "An over-pixel-dimension-ceiling image capture is rejected cleanly: nothing stored, no crash"
  )
  func rejectsOverPixelDimensionCeilingImageCaptureCleanly() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let monitor = ClipboardMonitor(store: store, blobStore: blobStore, pasteboard: pasteboard)
    let oversizedWidth = Int(PasteboardReader.maxCapturedImagePixelDimension) + 1
    let imageData = ImageFixtures.makeTinyImageData(width: oversizedWidth, height: 1)

    pasteboard.simulateImageCopy(data: imageData)
    let captured = await monitor.checkNow()

    #expect(captured == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  // MARK: - File capture (T20)

  @Test("Capturing a Finder file reference produces a .file item with the filename as previewText")
  func capturesFileReference() async throws {
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clip-\(UUID().uuidString).txt")
    try Data("file contents".utf8).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    pasteboard.simulateFileCopy(url: tempFile)
    let captured = await monitor.checkNow()

    #expect(captured?.kind == .file)
    #expect(captured?.previewText == tempFile.lastPathComponent)
    #expect(captured?.blobPath == nil)
    #expect(captured?.fileReference == tempFile.absoluteString)
  }

  @Test("Capturing a non-.file item (e.g. text) never sets fileReference")
  func nonFileCaptureLeavesFileReferenceNil() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    pasteboard.simulateCopy(text: "not a file")
    let captured = await monitor.checkNow()

    #expect(captured?.kind == .text)
    #expect(captured?.fileReference == nil)
  }

  @Test("captureEnabledProvider == false suppresses capture even on a real change")
  func captureDisabledProviderSuppressesCapture() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureEnabledProvider: { false }
    )

    pasteboard.simulateCopy(text: "should not be captured")
    let result = await monitor.checkNow()

    #expect(result == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("captureEnabledProvider is read fresh each cycle — flipping it to true re-enables capture")
  func captureEnabledProviderReadFreshEachCycle() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let enabled = MutableBox(false)
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureEnabledProvider: { enabled.value }
    )

    pasteboard.simulateCopy(text: "while disabled")
    #expect(await monitor.checkNow() == nil)

    enabled.value = true
    pasteboard.simulateCopy(text: "after enabling")
    let result = await monitor.checkNow()

    #expect(result?.previewText == "after enabling")
    let all = try await store.fetchAll()
    #expect(all.count == 1)
  }

  @Test("transient resume() does not override a disabled captureEnabledProvider")
  func transientResumeDoesNotOverrideUserPause() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      captureEnabledProvider: { false }  // user pause is ON
    )

    // Simulate the snippet-expansion clipboard borrow: transient pause then resume.
    monitor.pause()
    monitor.resume()

    pasteboard.simulateCopy(text: "still should not capture")
    let result = await monitor.checkNow()

    #expect(result == nil)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  // MARK: - On-device text recognition (T-OCR2)

  @Test(
    "When the setting is on, capturing an image runs recognition, persists the recognized text, and re-fires onCapture with it"
  )
  func recognitionRunsOnImageCaptureWhenEnabled() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "Recognized screenshot text")
    let recorder = CaptureRecorder()
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    monitor.onCapture = { item in recorder.record(item) }
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    pasteboard.simulateImageCopy(data: imageData)
    let captured = await monitor.checkNow()

    // The capture itself is immediate and carries no OCR text yet —
    // recognition hasn't run at the moment `checkNow()` returns.
    #expect(captured?.ocrText == nil)

    await waitUntil { await recognizer.recognizedImages.count == 1 }
    let all = try await store.fetchAll()
    #expect(all.first?.ocrText == "Recognized screenshot text")

    // onCapture fired twice: once for the fresh capture, once again once
    // recognition completed — the same hook the picker already uses to
    // requery, so no second UI-notification path was needed.
    #expect(recorder.capturedItems.count == 2)
    #expect(recorder.capturedItems.last?.ocrText == "Recognized screenshot text")

    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages == [imageData])
  }

  @Test("When the setting is off, capturing an image never runs recognition")
  func recognitionDoesNotRunWhenProviderDisabled() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "should never be used")
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { false }
    )

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 4, height: 4))
    _ = await monitor.checkNow()

    // Give any (incorrectly) scheduled recognition task a chance to run
    // before asserting it never did.
    await Task.yield()
    await Task.yield()
    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.isEmpty)
    let all = try await store.fetchAll()
    #expect(all.first?.ocrText == nil)
  }

  @Test("Recognition never runs for a non-.image capture, even with the setting on")
  func recognitionOnlyRunsForImageKind() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let recognizer = FakeTextRecognizer(result: "should never be used")
    let monitor = ClipboardMonitor(
      store: store,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )

    pasteboard.simulateCopy(text: "plain text, not an image")
    let captured = await monitor.checkNow()

    #expect(captured?.kind == .text)
    await Task.yield()
    await Task.yield()
    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.isEmpty)
  }

  @Test(
    "Re-copying an image that already has recognized text does not run recognition a second time"
  )
  func recognitionSkipsAlreadyRecognizedDuplicate() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized once")
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    let imageData = ImageFixtures.makeTinyImageData(width: 6, height: 6)

    pasteboard.simulateImageCopy(data: imageData)
    _ = await monitor.checkNow()
    await waitUntil { await recognizer.recognizedImages.count == 1 }

    // A second copy of the SAME image dedup-bumps the existing row (which
    // now already has ocrText from the first recognition) rather than
    // inserting a fresh one — see `insertOrBumpDuplicate`'s doc comment.
    pasteboard.simulateImageCopy(data: imageData)
    let secondCapture = await monitor.checkNow()
    #expect(secondCapture?.ocrText == "recognized once")

    // Give a wrongly-rescheduled recognition a chance to run before
    // asserting it didn't.
    await Task.yield()
    await Task.yield()
    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.count == 1)
  }

  @Test("checkNow() returns before recognition completes — capture latency is unaffected")
  func recognitionDoesNotBlockCheckNow() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "eventually recognized", gated: true)
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    let imageData = ImageFixtures.makeTinyImageData(width: 8, height: 8)

    pasteboard.simulateImageCopy(data: imageData)
    // `checkNow()` completes on its own even though `recognizer` is gated
    // and hasn't returned yet — proves this call never awaits recognition.
    let captured = await monitor.checkNow()
    #expect(captured != nil)

    await waitUntil { await recognizer.recognizedImages.count == 1 }
    // Recognition has STARTED (the gate is inside `recognizeText`, entered
    // after `checkNow()` already returned above) but not finished — the
    // stored item must still show no recognized text yet.
    let beforeRelease = try await store.fetchAll()
    #expect(beforeRelease.first?.ocrText == nil)

    await recognizer.release()
    await waitUntil {
      let all = try? await store.fetchAll()
      return all?.first?.ocrText == "eventually recognized"
    }
    let all = try await store.fetchAll()
    #expect(all.first?.ocrText == "eventually recognized")
  }

  // MARK: - Adversarial OCR cases (T-OCR3 tester follow-up)
  //
  // The four tests below close gaps the reviewer flagged or that the
  // wiring tests above don't reach: two rapid duplicate copies racing
  // before the first Vision pass completes, an item deleted/history
  // cleared while an OCR write is still in flight, and the setting being
  // toggled mid-session without recreating ClipboardMonitor. Written by
  // tester (T-OCR3), not senior-dev — production code is unchanged by
  // these; they exercise exactly the wiring already built in
  // `checkNow()`/`scheduleTextRecognition`.

  @Test(
    "Two rapid copies of the identical image, both landing before the first Vision pass completes, run concurrently without crashing or corrupting the store — exactly one item, a valid final ocrText, no duplicate rows"
  )
  func recognitionHandlesConcurrentDuplicateCopiesBeforeFirstPassCompletes() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized text", gated: true)
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    let imageData = ImageFixtures.makeTinyImageData(width: 5, height: 5)

    // First copy: schedules recognition #1, which immediately suspends on
    // the gate before returning a result.
    pasteboard.simulateImageCopy(data: imageData)
    let first = try #require(await monitor.checkNow())
    await waitUntil { await recognizer.pendingGateCount == 1 }
    #expect(first.ocrText == nil)

    // Second copy of the IDENTICAL image, before recognition #1 has
    // written anything back: `insertOrBumpDuplicate` dedup-bumps the same
    // stored row (still `ocrText == nil`, since #1 hasn't completed), so
    // `checkNow()`'s `stored.ocrText == nil` guard passes again and a
    // SECOND recognition task is scheduled concurrently for the same item
    // id. This is the exact race the reviewer flagged as
    // "idempotent-but-untested."
    pasteboard.simulateImageCopy(data: imageData)
    let second = try #require(await monitor.checkNow())
    #expect(second.id == first.id)
    #expect(second.ocrText == nil)

    // Prove BOTH recognitions are genuinely in flight at once before
    // either is allowed to complete — this is what makes it a real
    // concurrent race rather than two sequential calls that only look
    // concurrent from the outside.
    await waitUntil { await recognizer.pendingGateCount == 2 }
    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages == [imageData, imageData])

    // Release both, oldest first. Neither write throws or crashes.
    await recognizer.release()
    await recognizer.release()
    await waitUntil { await recognizer.pendingGateCount == 0 }
    await waitUntil {
      let all = try? await store.fetchAll()
      return all?.first?.ocrText != nil
    }

    let all = try await store.fetchAll()
    // Still exactly ONE row — the second capture bumped the existing item
    // rather than inserting a duplicate, and neither recognition write
    // created a second row.
    #expect(all.count == 1)
    #expect(all.first?.id == first.id)
    // The store ends in a valid, non-corrupted state (both concurrent
    // writers used the same recognized text here, so this also confirms
    // whichever write actually lands last is a normal, well-formed
    // `setRecognizedText` call, not a partial/garbled one).
    #expect(all.first?.ocrText == "recognized text")
  }

  @Test(
    "An item deleted while its OCR write is still in flight surfaces the store's .notFound failure internally and is not resurrected"
  )
  func recognitionWriteAfterDeleteDoesNotResurrectItem() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized after delete", gated: true)
    let recorder = CaptureRecorder()
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    monitor.onCapture = { item in recorder.record(item) }
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    pasteboard.simulateImageCopy(data: imageData)
    let captured = try #require(await monitor.checkNow())
    await waitUntil { await recognizer.pendingGateCount == 1 }

    // Delete the item WHILE recognition is still suspended, mid-flight —
    // models a user hitting the row's delete action (or ⌘⌫) in the exact
    // window between capture and the OCR write landing.
    try await store.delete(captured.id)
    let afterDelete = try await store.fetchAll()
    #expect(afterDelete.isEmpty)

    // Let recognition complete now — its `store.setRecognizedText(captured
    // .id, ...)` call must find nothing and throw `.notFound` internally
    // (verified indirectly below: no resurrection, no second onCapture).
    await recognizer.release()
    await waitUntil { await recognizer.pendingGateCount == 0 }
    // Give the detached task's error-handling `catch` branch a moment to
    // actually run past the `await` boundary above.
    await Task.yield()
    await Task.yield()
    await Task.yield()

    let afterRecognition = try await store.fetchAll()
    // The deleted item must stay deleted — no resurrection via the OCR
    // write landing after the delete.
    #expect(afterRecognition.isEmpty)
    // Only the ONE onCapture from the original successful capture fired;
    // recognition's write failed (caught internally), so it never reaches
    // the `onCapture`-refire call on this path — no phantom notification
    // for a row that no longer exists.
    #expect(recorder.capturedItems.count == 1)
  }

  @Test(
    "clearHistory() while an item's OCR write is still in flight surfaces the store's .notFound failure internally and resurrects nothing"
  )
  func recognitionWriteAfterClearHistoryDoesNotResurrectAnyItem() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized after clear", gated: true)
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    pasteboard.simulateImageCopy(data: imageData)
    _ = await monitor.checkNow()
    await waitUntil { await recognizer.pendingGateCount == 1 }

    // Clear the WHOLE history while recognition is still in flight —
    // models "Clear All History…" firing in that same narrow window.
    try await store.clearHistory()
    let afterClear = try await store.fetchAll()
    #expect(afterClear.isEmpty)

    await recognizer.release()
    await waitUntil { await recognizer.pendingGateCount == 0 }
    await Task.yield()
    await Task.yield()
    await Task.yield()

    let afterRecognition = try await store.fetchAll()
    #expect(afterRecognition.isEmpty)
  }

  @Test(
    "Toggling the text-recognition setting mid-session (without recreating ClipboardMonitor) takes effect on the very next capture, in both directions"
  )
  func togglingSettingMidSessionTakesEffectImmediately() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized once enabled")
    let enabled = MutableBox(false)
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      // Reads `enabled.value` FRESH on every call — the same shape
      // `AppEnvironment` wires `textRecognitionEnabledProvider` to
      // `settingsStore.isTextRecognitionEnabled` (a live `@Observable`
      // property, no `ClipboardMonitor` re-construction on toggle).
      textRecognitionEnabledProvider: { enabled.value }
    )

    // Setting starts OFF: copying an image does no recognition work.
    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 4, height: 4))
    _ = await monitor.checkNow()
    await Task.yield()
    await Task.yield()
    var recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.isEmpty)

    // Flip the SAME live provider value mid-session — no new monitor, no
    // restart.
    enabled.value = true

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 6, height: 6))
    let captured = await monitor.checkNow()
    await waitUntil { await recognizer.recognizedImages.count == 1 }
    let all = try await store.fetchAll()
    #expect(all.first(where: { $0.id == captured?.id })?.ocrText == "recognized once enabled")

    // Flip back OFF: a third copy runs no recognition again, proving the
    // toggle is genuinely live in both directions, not a one-time latch.
    enabled.value = false
    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 8, height: 8))
    _ = await monitor.checkNow()
    await Task.yield()
    await Task.yield()
    recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.count == 1)  // unchanged since the ON-copy above
  }

  @Test(
    "T-OCR8: changing the recognition-quality setting mid-session (without recreating ClipboardMonitor) takes effect on the very next capture"
  )
  func changingQualityMidSessionTakesEffectImmediately() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized text")
    let quality = MutableBox(TextRecognitionQuality.fast)
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true },
      // Reads `quality.value` FRESH on every call — the same shape
      // `AppEnvironment` wires `textRecognitionQualityProvider` to
      // `settingsStore.textRecognitionQuality` (a live `@Observable`
      // property, no `ClipboardMonitor`/`VisionTextRecognizer` re-creation
      // on a Fast<->Accurate change). Asserted via the FAKE recognizer's
      // `recognizedQualities`, per T-OCR8's spec: never depend on real
      // Vision for this wiring assertion.
      textRecognitionQualityProvider: { quality.value }
    )

    // Setting starts .fast: the first copy's recognition request carries
    // .fast.
    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 4, height: 4))
    _ = await monitor.checkNow()
    await waitUntil { await recognizer.recognizedImages.count == 1 }
    var recognizedQualities = await recognizer.recognizedQualities
    #expect(recognizedQualities == [.fast])

    // Flip the SAME live provider value mid-session — no new monitor, no
    // restart.
    quality.value = .accurate

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 6, height: 6))
    _ = await monitor.checkNow()
    await waitUntil { await recognizer.recognizedImages.count == 2 }
    recognizedQualities = await recognizer.recognizedQualities
    #expect(recognizedQualities == [.fast, .accurate])
  }

  @Test(
    "An image copy carrying the concealed marker is never captured or recognized, even with the setting on"
  )
  func recognitionNeverRunsForConcealedImage() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "should never be used")
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 4, height: 4))
    pasteboard.availableTypes.append(PrivacyFilter.concealedPasteboardType)
    let result = await monitor.checkNow()

    #expect(result == nil)
    await Task.yield()
    await Task.yield()
    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.isEmpty)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  @Test(
    "An image copied from an excluded app is never captured or recognized, even with the setting on"
  )
  func recognitionNeverRunsForExcludedAppImage() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "should never be used")
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(
        frontmostBundleID: "com.example.excluded", frontmostAppName: "Excluded App"),
      excludedBundleIDsProvider: { ["com.example.excluded"] },
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 4, height: 4))
    let result = await monitor.checkNow()

    #expect(result == nil)
    await Task.yield()
    await Task.yield()
    let recognizedImages = await recognizer.recognizedImages
    #expect(recognizedImages.isEmpty)
    let all = try await store.fetchAll()
    #expect(all.isEmpty)
  }

  // MARK: - T-OCR6: OCR store-write failures route through the injected handler

  @Test(
    "T-OCR6: a store-write failure during capture-time recognition is routed through the injected captureFailureHandler, not the static default logger"
  )
  func recognitionWriteFailureRoutesThroughInjectedCaptureFailureHandler() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized after delete", gated: true)
    let recorder = CaptureFailureRecorder()
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true },
      captureFailureHandler: recorder.handle
    )
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    pasteboard.simulateImageCopy(data: imageData)
    let captured = try #require(await monitor.checkNow())
    await waitUntil { await recognizer.pendingGateCount == 1 }

    // Delete the item while recognition is still in flight (same setup as
    // `recognitionWriteAfterDeleteDoesNotResurrectItem`) so
    // `store.setRecognizedText` throws `.notFound` once recognition
    // completes -- this test's own assertion is on WHERE that failure goes,
    // not on the resurrection behavior itself (already covered elsewhere).
    try await store.delete(captured.id)

    await recognizer.release()
    await waitUntil { recorder.reportedError != nil }

    #expect(recorder.reportedError as? ClipStoreError == .notFound)
  }

  // MARK: - T-HANG5: capture-time OCR backlog cancellation

  @Test("T-HANG5: cancelPendingRecognition(for:) for an id with no pending job is a safe no-op")
  func cancelPendingRecognitionNoOpForUnknownID() async throws {
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore()
    let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

    monitor.cancelPendingRecognition(for: UUID())
    monitor.cancelAllPendingRecognition()

    // No crash, and normal (non-OCR) capture still works afterward.
    pasteboard.simulateCopy(text: "still works")
    let result = await monitor.checkNow()
    #expect(result?.previewText == "still works")
  }

  @Test(
    "T-HANG5: cancelPendingRecognition(for:) called while recognition is in flight suppresses the write and the onCapture refire, even though Vision already returned text"
  )
  func cancelPendingRecognitionSuppressesLateWrite() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized text", gated: true)
    let recorder = CaptureRecorder()
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )
    monitor.onCapture = { item in recorder.record(item) }
    let imageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    pasteboard.simulateImageCopy(data: imageData)
    let captured = try #require(await monitor.checkNow())
    await waitUntil { await recognizer.pendingGateCount == 1 }

    // Recognition has genuinely started (recorded the image, suspended
    // inside recognizeText, i.e. `scheduleTextRecognition`'s pre-Vision
    // Task.isCancelled check has already passed) -- cancel now, strictly
    // BEFORE `release()` lets it return. `cancel()` is synchronous and
    // completes before `release()` is even called below, so the resumed
    // task's post-recognition `Task.isCancelled` check is guaranteed (not
    // racy) to observe cancellation -- see `pendingRecognitionTasks`'s doc
    // comment for why this ordering, not real timing, is what makes this
    // deterministic.
    monitor.cancelPendingRecognition(for: captured.id)
    await recognizer.release()
    await waitUntil { await recognizer.pendingGateCount == 0 }
    // Give the cancelled task's own remaining (non-awaited) steps a moment
    // to run past its `Task.isCancelled` check and return.
    await Task.yield()
    await Task.yield()
    await Task.yield()

    let all = try await store.fetchAll()
    #expect(all.first?.ocrText == nil)
    // Only the original capture's onCapture fired -- no refire for the
    // cancelled recognition's (never-written) result.
    #expect(recorder.capturedItems.count == 1)
  }

  @Test(
    "T-HANG5: cancelAllPendingRecognition() cancels every currently-pending job, suppressing all their writes"
  )
  func cancelAllPendingRecognitionSuppressesAllPendingWrites() async throws {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    let recognizer = FakeTextRecognizer(result: "recognized text", gated: true)
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      textRecognizer: recognizer,
      textRecognitionEnabledProvider: { true }
    )

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 4, height: 4))
    let first = try #require(await monitor.checkNow())
    await waitUntil { await recognizer.pendingGateCount == 1 }

    pasteboard.simulateImageCopy(data: ImageFixtures.makeTinyImageData(width: 6, height: 6))
    let second = try #require(await monitor.checkNow())
    await waitUntil { await recognizer.pendingGateCount == 2 }

    monitor.cancelAllPendingRecognition()
    await recognizer.release()
    await recognizer.release()
    await waitUntil { await recognizer.pendingGateCount == 0 }
    await Task.yield()
    await Task.yield()
    await Task.yield()

    let all = try await store.fetchAll()
    #expect(all.first(where: { $0.id == first.id })?.ocrText == nil)
    #expect(all.first(where: { $0.id == second.id })?.ocrText == nil)
  }

  // MARK: - T-PERF3: checkNow's classify step genuinely runs off the main actor

  @Test(
    "checkNow's classify step runs off the main actor -- a heartbeat's worst gap stays far below classify()'s own solo duration (T-PERF3)"
  )
  @MainActor
  func checkNowClassifyDoesNotBlockTheMainActor() async throws {
    // Best-of-N attempts, NOT a single measurement: `swift test` runs this
    // alongside ~200 other tests, many themselves using `Task.detached`/
    // real concurrency -- under that shared-thread-pool contention, even
    // the CORRECT (offloaded) implementation can occasionally see an
    // inflated gap purely from system-wide scheduling noise (observed:
    // running solo, maxGap stayed under 6% of the solo baseline across 10
    // repeats; running inside the full 218-test suite, one attempt spiked
    // to ~30x the solo baseline with the SAME correct code, from unrelated
    // tests saturating the pool -- not from `checkNow()` itself blocking).
    // A genuine regression (inline `classify`) cannot benefit from a
    // retry: the main actor is structurally monopolized for classify()'s
    // full duration every single time, contention or not (confirmed: 6/6
    // manual regression runs failed the single-attempt version of this
    // check, both solo and under load). So "does the BEST of several
    // attempts clear the bar" stays a genuine, non-flaky proof: a
    // regression fails every attempt; the real implementation only needs
    // one clean window to succeed, and reliably gets one.
    //
    // T-PERF3-CI (GitHub Actions run 33914926870, macos-26 runner, 2026-09):
    // the previous 5-attempt loop still lost every attempt in one CI run
    // (bestRatio 1.10, needed < 0.33) even though `classify` was genuinely
    // offloaded (production untouched -- independently re-verified for this
    // fix by temporarily reverting `checkNow()` to an inline, blocking
    // `classify` call and confirming this test goes red, then restoring the
    // exact original production code -- see this task's log for that
    // before/after diff and output). Root cause isn't this test's core
    // logic; it's CI's much smaller runner (a handful of cores vs. this
    // machine's many) combined with this session's new suites that run
    // sustained background `Task.detached` work of their own (e.g.
    // `ImageContentHashBackfillCoordinatorTests`'s slow-hasher case,
    // `SwiftDataClipStoreTests`'s backfill-under-load cases) --
    // `swift-testing` parallelizes across suites by default, and a
    // `.serialized` trait (used elsewhere in this file's neighbors) only
    // serializes tests WITHIN the suite it's applied to, never against
    // OTHER suites, so those suites' bursts can and do land squarely
    // inside a back-to-back retry's whole few-hundred-ms span on a small
    // runner.
    //
    // Two changes fix this, both verified empirically against a real,
    // temporarily-reintroduced regression (inline `classify`, no
    // `Task.detached`) on a heavily loaded machine (system-wide load
    // average 30-50 from unrelated processes, well beyond anything CI
    // presents -- see `measureClassifyOffloadRatio`'s doc comment for the
    // calibration-hardening half of this fix):
    //   1. More attempts (5 -> 10), paced with a few `Task.yield()`s
    //      between them (NOT a real `Task.sleep` -- that was tried first
    //      and made things WORSE, see below) so a correct implementation
    //      gets more independent chances at a clean scheduling window
    //      without ever touching the 1/3 bar itself.
    //   2. `measureClassifyOffloadRatio`'s solo calibration is now the
    //      MINIMUM of 5 quick back-to-back samples, not one. A single
    //      sample is itself a noise-prone measurement: instrumented
    //      against the real (reverted) regression, one attempt's lone
    //      calibration sample measured 0.157s against sibling attempts'
    //      0.016-0.047s -- a scheduling stall during JUST that one call,
    //      nothing to do with `checkNow()` -- which alone dragged that
    //      attempt's ratio under 1/3 and produced a false PASS on a
    //      genuinely main-actor-blocking `classify`. More outer attempts
    //      with an unhardened calibration only gave this failure mode
    //      MORE chances to fire (confirmed: adding attempts alone, or
    //      attempts + real `Task.sleep`, both measurably INCREASED the
    //      false-pass rate against the same reverted regression -- the
    //      `Task.sleep` variant let it through in roughly 1 of 3 runs).
    //      Hardening calibration to a minimum-of-5 fixes this because
    //      contention can only ever slow a real call down, never make it
    //      faster than its true unblocked cost -- taking the minimum
    //      converges toward that true cost and discards a slow outlier
    //      instead of trusting it.
    // With both changes, 30/30 then 39/40 repeated runs against the same
    // reintroduced regression correctly failed on this same heavily loaded
    // machine (the one false pass that did occur is disclosed, not hidden:
    // a residual, very-low-probability risk under this specific
    // exceptionally adversarial environment -- unrelated processes on a
    // shared dev machine, not this repo's own test suites -- remains
    // possible in principle; CI's contention sources are bounded to this
    // repo's own suites, so the real-world rate there should be
    // substantially lower). If this residual ever becomes a practical
    // problem, the honest next step is moving this measurement to
    // `tools/stress-harness` (this repo's precedent for timing/concurrency
    // proofs that need to run outside a parallel unit-test process), not
    // further loosening this test.
    let maxAttempts = 10
    var bestRatio = Double.infinity
    var lastCaptured: ClipItem?
    var lastByteCount = 0
    for attemptIndex in 0..<maxAttempts {
      if attemptIndex > 0 {
        for _ in 0..<3 { await Task.yield() }
      }
      let (ratio, captured, byteCount) = try await measureClassifyOffloadRatio()
      bestRatio = min(bestRatio, ratio)
      lastCaptured = captured
      lastByteCount = byteCount
      // Stop as soon as one clean attempt clears the bar -- no need to
      // keep burning CPU (each attempt hashes 25MB) once proven.
      if ratio < (1.0 / 3.0) { break }
    }

    #expect(lastCaptured != nil)
    #expect(lastByteCount == 25_000_000)
    // See this function's doc comment for why "best of 10" (not 5) and why
    // a regression can't game it. `bestRatio` is
    // `maxGap / soloClassifyDuration` for whichever attempt had the
    // cleanest scheduling window. The bar itself is UNCHANGED at 1/3 --
    // only how many clean-window chances a correct implementation gets to
    // clear it has changed.
    #expect(bestRatio < 1.0 / 3.0)
  }

  /// One attempt of T-PERF3's measurement: builds a fresh
  /// `ClipboardMonitor` + 25MB synthetic image, calibrates a solo
  /// `classify()` call, then drives `checkNow()` itself while a
  /// `@MainActor` heartbeat races alongside, tracking the worst gap
  /// between ticks. Returns `maxGap / soloClassifyDuration` (smaller is
  /// better -- offloaded work should keep this near zero) plus the
  /// captured item and its byte count for the caller's sanity checks.
  /// Extracted into its own call (rather than inlined in the test) so
  /// `checkNowClassifyDoesNotBlockTheMainActor` can retry it -- see that
  /// function's doc comment for why a retry is needed and why it can't
  /// mask a genuine regression.
  ///
  /// Closes the gap the reviewer flagged in `PasteboardReaderTests
  /// .classifyRunsOffTheMainThread`: that test only proves `classify(_:)`
  /// itself CAN run off-main -- it wraps the call in `Task.detached`
  /// ITSELF, so it says nothing about whether `ClipboardMonitor
  /// .checkNow()` (the only real caller) actually calls it that way. A
  /// future "simplification" of `checkNow()` back to an inline
  /// `reader.classify(rawPayload)` call would compile and pass every
  /// existing test unnoticed, silently reintroducing the exact main-actor
  /// stall T-PERF1 exists to fix.
  ///
  /// This measures `checkNow()` itself -- not `classify` directly -- via a
  /// `@MainActor` heartbeat's WORST GAP between ticks (not a plain tick
  /// count -- see below for why that's not enough here).
  ///
  /// A plain `#expect(tickCount > 0)` (the shape `PasterTests
  /// .imageDecodeDoesNotBlockTheCallingActor` uses) does NOT work at the
  /// `checkNow()` level, for two independent reasons found while building
  /// this test (both confirmed empirically against this exact `swift test`
  /// binary via a throwaway diagnostic, not checked in -- instructed to
  /// verify by watching this test genuinely fail against a reverted
  /// `checkNow()`, so this is that verification, not a guess):
  ///   1. `checkNow()` has OTHER genuine off-main hops AFTER `classify`
  ///      (the blob write, `store.insertOrBumpDuplicate`), so even a fully
  ///      inline/regressed `classify` call still lets the heartbeat tick
  ///      thousands of times total once execution reaches those later
  ///      hops -- `tickCount` alone stayed in the thousands either way and
  ///      never distinguished the two cases in practice.
  ///   2. The default `frontmostApplicationProvider`
  ///      (`WorkspaceFrontmostApplicationProvider`, real `NSWorkspace`)
  ///      must NOT be used here -- a fake is passed explicitly below. Every
  ///      other test in this file uses the real-vs-fake choice
  ///      interchangeably since none of them measure timing; this is the
  ///      first one that does, so it's the first one where that call's own
  ///      real-system-call cost would pollute the measurement window.
  /// Measuring the worst GAP between ticks instead -- and comparing it
  /// against a solo, untimed call to the exact same `classify` on the same
  /// payload, done first and self-calibrating (no brittle fixed-
  /// millisecond constant, robust to whatever machine/CI runs this) -- DOES
  /// discriminate: `maxGap` reflects whichever single stretch the main
  /// actor was actually frozen for, regardless of what legitimate off-main
  /// work happens elsewhere in the same call. Measured, repeatedly (5 runs
  /// each, solo), on this exact check against both shapes:
  ///   - Correct (offloaded): maxGap consistently under 6% of
  ///     `soloClassifyDuration` (e.g. 0.06-0.7ms of a ~13ms solo baseline).
  ///   - Reverted to `let result = reader.classify(rawPayload)` (no
  ///     `Task.detached`): maxGap consistently 65-70% of
  ///     `soloClassifyDuration` (e.g. ~8.3ms of a ~12.3ms solo baseline),
  ///     both solo AND inside the full 218-test suite.
  /// The 1/3 (~33%) threshold the caller checks sits with real margin on
  /// both sides of that observed gap -- 2x+ margin under the regressed
  /// ratio, 5x+ margin over the offloaded ratio.
  @MainActor
  private func measureClassifyOffloadRatio() async throws -> (
    ratio: Double, captured: ClipItem?, byteCount: Int
  ) {
    let (blobStore, baseDirectory) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let pasteboard = FakeMonitoredPasteboard(changeCount: 0)
    let store = InMemoryClipStore(blobStore: blobStore)
    // A fake `frontmostApplicationProvider`, NOT the default
    // `WorkspaceFrontmostApplicationProvider()`: that default calls real
    // `NSWorkspace.shared.frontmostApplication`, which can pump the run
    // loop internally while waiting on the WindowServer -- and, as a side
    // effect, let other already-queued MainActor work (like this
    // measurement's own heartbeat task) advance during a call this
    // measurement needs to be a clean window. Every other test in this
    // file uses the real-vs-fake choice interchangeably since none of them
    // measure timing; this is the first one that does.
    let monitor = ClipboardMonitor(
      store: store,
      blobStore: blobStore,
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(
        frontmostBundleID: "com.apple.TextEdit", frontmostAppName: "TextEdit")
    )

    // Zero-filled bytes, not a real decodable image: SHA-256 cost (what
    // `classify`'s `contentHash` actually pays for) is purely a function of
    // BYTE COUNT, not content/entropy, so this is representative of a real
    // large capture's classify cost without the multi-second overhead of
    // generating genuinely-random pixel data. `imagePixelDimensions`
    // gracefully fails to decode these as a real image (falls back to the
    // byte-count preview branch) -- irrelevant here, nothing asserts on
    // `previewText`. Large enough (25MB, matching the user's real captured
    // screenshot size referenced in this task) that `classify`'s SHA-256
    // hash takes several milliseconds even under a debug (-Onone) build.
    let largeImageData = Data(count: 25_000_000)

    // Solo calibration: how long does classify() alone take on this exact
    // payload, on this exact machine, right now? Never awaited/timed
    // concurrently with anything else, so this is a clean baseline for
    // THIS attempt (recomputed fresh every attempt, so a slower/faster
    // machine, or a slower/faster moment under contention, doesn't skew
    // the ratio -- both numerator and denominator come from the same
    // narrow window).
    //
    // T-PERF3-CI follow-up: a SINGLE calibration sample is not safe on a
    // heavily contended machine -- instrumented and confirmed directly
    // (debug run against a temporarily-reintroduced, genuinely-blocking
    // `classify` call): one attempt's lone calibration sample measured
    // 0.157s against sibling attempts' 0.016-0.047s (a ~10x outlier) purely
    // from a scheduling stall DURING the calibration call itself, while
    // that same attempt's `checkNow()` maxGap stayed a normal 0.021s --
    // an inflated DENOMINATOR alone dragged the ratio under 1/3 and made a
    // genuinely main-actor-blocking `classify` register as a false PASS.
    // More retries of a single-sample calibration only give this failure
    // mode more chances to fire (verified: it did, at roughly the same
    // rate with or without a pause between attempts). Contention can only
    // ever SLOW a real call down, never make it faster than its true
    // unblocked cost, so taking the MINIMUM of 5 quick, immediately-
    // repeated calibration samples converges toward that true cost and
    // discards a slow outlier instead of trusting it -- unlike retrying
    // the OUTER best-of-N measurement (which is symmetric risk: it can
    // just as easily rescue a false PASS as a true one), a lower minimum
    // calibration sample is never less accurate, so this doesn't trade
    // away any regression-detection power.
    let reader = PasteboardReader()
    let soloRaw = PasteboardReader.RawPayload.image(largeImageData)
    let calibrationClock = ContinuousClock()
    var soloClassifyDuration = Duration.zero
    for sample in 0..<5 {
      let calibrationStart = calibrationClock.now
      _ = reader.classify(soloRaw)
      let sampleDuration = calibrationClock.now - calibrationStart
      if sample == 0 || sampleDuration < soloClassifyDuration {
        soloClassifyDuration = sampleDuration
      }
    }

    pasteboard.simulateImageCopy(data: largeImageData)

    final class Heartbeat: @unchecked Sendable {
      private(set) var maxGap: Duration = .zero
      private var lastTick = ContinuousClock.now

      func tick() {
        let now = ContinuousClock.now
        let gap = now - lastTick
        if gap > maxGap { maxGap = gap }
        lastTick = now
      }

      /// A fully-blocked run records exactly one tick (right after warm-
      /// up, before the blocking call starts) and never gets a second one
      /// to diff against, so without a final "close-out" gap against
      /// `now`, `maxGap` would misreport ~0 for the worst possible
      /// blocking case.
      func closeOutGap(now: ContinuousClock.Instant) {
        let gap = now - lastTick
        if gap > maxGap { maxGap = gap }
      }
    }
    let heartbeat = Heartbeat()
    let heartbeatTask = Task { @MainActor in
      while !Task.isCancelled {
        heartbeat.tick()
        await Task.yield()
      }
    }
    defer { heartbeatTask.cancel() }
    // Let the heartbeat warm up before starting the timed work, so its
    // first recorded gap isn't polluted by task-startup scheduling noise.
    await Task.yield()
    await Task.yield()

    let runClock = ContinuousClock()
    let captured = await monitor.checkNow()
    let checkNowEnd = runClock.now
    heartbeat.closeOutGap(now: checkNowEnd)
    heartbeatTask.cancel()

    let ratio = soloClassifyDuration > .zero ? heartbeat.maxGap / soloClassifyDuration : 0
    return (ratio, captured, captured?.byteSize ?? -1)
  }
}

// MARK: - P2-A (Linux port): PollScheduling extraction

/// Spies on `ClipboardMonitor`'s calls into the injected `PollScheduling`,
/// so `start()`/`stop()`/`startEventDriven()` can be tested without a real
/// `Timer` (per coding-standards.md's testing rules: "never touch...a real
/// `Timer`... from a test"). Previously these three methods had NO test
/// coverage at all (confirmed: no existing test in this file called any of
/// them) — this extraction is also what makes them newly testable.
private final class FakePollScheduling: PollScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var scheduleCallCountStorage = 0
  private var cancelCallCountStorage = 0
  private var lastIntervalStorage: TimeInterval?

  var scheduleCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return scheduleCallCountStorage
  }

  var cancelCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancelCallCountStorage
  }

  var lastInterval: TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return lastIntervalStorage
  }

  func schedule(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
    lock.lock()
    scheduleCallCountStorage += 1
    lastIntervalStorage = interval
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelCallCountStorage += 1
    lock.unlock()
  }
}

@Suite("ClipboardMonitor poll scheduling (P2-A)")
struct ClipboardMonitorPollSchedulingTests {
  @MainActor
  private func makeMonitor(pollScheduler: FakePollScheduling, pollInterval: TimeInterval = 0.4)
    -> ClipboardMonitor
  {
    ClipboardMonitor(
      store: InMemoryClipStore(),
      pasteboard: FakeMonitoredPasteboard(),
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(),
      pollInterval: pollInterval,
      pollScheduler: pollScheduler
    )
  }

  @MainActor
  @Test("start() schedules exactly once, at pollInterval, via the injected PollScheduling")
  func startSchedulesOnceAtPollInterval() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler, pollInterval: 0.7)

    monitor.start()

    #expect(scheduler.scheduleCallCount == 1)
    #expect(scheduler.lastInterval == 0.7)
    #expect(scheduler.cancelCallCount == 0)
  }

  @MainActor
  @Test("Calling start() twice schedules only once — ClipboardMonitor owns the idempotency guard")
  func startIsIdempotent() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    monitor.start()
    monitor.start()

    #expect(scheduler.scheduleCallCount == 1)
  }

  @MainActor
  @Test("stop() cancels the injected PollScheduling after start()")
  func stopCancelsAfterStart() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    monitor.start()
    monitor.stop()

    #expect(scheduler.cancelCallCount == 1)
  }

  @MainActor
  @Test("stop() without a prior start() never calls cancel — nothing was ever scheduled")
  func stopWithoutStartDoesNotCancel() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    monitor.stop()

    #expect(scheduler.cancelCallCount == 0)
  }

  @MainActor
  @Test("A stop()-then-start() cycle schedules again — stop() resets the idempotency guard")
  func stopThenStartSchedulesAgain() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    monitor.start()
    monitor.stop()
    monitor.start()

    #expect(scheduler.scheduleCallCount == 2)
    #expect(scheduler.cancelCallCount == 1)
  }

  @MainActor
  @Test("startEventDriven() never touches the injected PollScheduling")
  func startEventDrivenNeverSchedules() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    #expect(monitor.isEventDriven == false)
    monitor.startEventDriven()

    #expect(monitor.isEventDriven == true)
    #expect(scheduler.scheduleCallCount == 0)
    #expect(scheduler.cancelCallCount == 0)
  }

  @MainActor
  @Test("startEventDriven() after start() stops the active polling first")
  func startEventDrivenStopsActivePolling() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    monitor.start()
    monitor.startEventDriven()

    #expect(scheduler.scheduleCallCount == 1)
    #expect(scheduler.cancelCallCount == 1)
    #expect(monitor.isEventDriven == true)
  }

  @MainActor
  @Test(
    "checkNow() works with no start()/startEventDriven() call at all — event-driven callers need neither"
  )
  func checkNowWorksWithoutStartingAnything() async {
    let scheduler = FakePollScheduling()
    let pasteboard = FakeMonitoredPasteboard()
    let monitor = ClipboardMonitor(
      store: InMemoryClipStore(),
      pasteboard: pasteboard,
      frontmostApplicationProvider: FakeFrontmostApplicationProvider(),
      pollScheduler: scheduler
    )
    pasteboard.simulateCopy(text: "no start() needed")

    let captured = await monitor.checkNow()

    #expect(captured?.previewText == "no start() needed")
    #expect(scheduler.scheduleCallCount == 0)
  }

  @MainActor
  @Test("stop() clears the startEventDriven() marker too")
  func stopClearsEventDrivenMarker() {
    let scheduler = FakePollScheduling()
    let monitor = makeMonitor(pollScheduler: scheduler)

    monitor.startEventDriven()
    monitor.stop()

    #expect(monitor.isEventDriven == false)
  }
}
