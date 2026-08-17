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
  /// `.string` representation.
  func simulateImageCopy(data: Data) {
    strings = [:]
    datas = [.png: data]
    availableTypes = [.png]
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

/// A single mutable `Bool` box, so a test's `captureEnabledProvider` closure
/// can read a flag that the test body flips mid-test. Same "plain wrapper is
/// fine" reasoning as `CaptureFailureRecorder`/`CaptureRecorder` below: only
/// ever touched sequentially from this @MainActor test body, never
/// concurrently. Avoids capturing a raw `var` directly in a `@Sendable`
/// closure, which Swift 6 strict concurrency flags even though the access
/// here is provably sequential.
private final class MutableFlag: @unchecked Sendable {
  var value: Bool
  init(_ value: Bool) { self.value = value }
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
    let enabled = MutableFlag(false)
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
}
