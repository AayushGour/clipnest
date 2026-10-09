// T-PASTEORDER1: the picker/pasteboard-write order is per-platform
// (`PasteDismissOrdering`). Linux must write BEFORE hiding (mutter drops a
// selection write from an unfocused client); macOS must still hide first.
// Proven by recorded call ORDER through a real `Paster`, not by timing.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

/// Shared, ordered event log for the fakes below.
final class PasteOrderLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func record(_ event: String) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(event)
  }

  var events: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

/// A pasteboard that logs writes. `bumpDelay == nil` bumps `changeCount`
/// synchronously (macOS-like); otherwise the bump lands later on another task
/// (Linux-like: the X11 event thread reports the owner change asynchronously),
/// `neverBumps` models a compositor that never reports it, and `manualBump`
/// holds the bump until the test calls `releaseBump()` (no wall-clock races).
final class OrderRecordingPasteboard: PasteboardWriting, @unchecked Sendable {
  private let log: PasteOrderLog
  private let bumpDelay: Duration?
  private let neverBumps: Bool
  private let manualBump: Bool
  private let lock = NSLock()
  private var count = 100

  init(
    log: PasteOrderLog, bumpDelay: Duration? = nil, neverBumps: Bool = false,
    manualBump: Bool = false
  ) {
    self.log = log
    self.manualBump = manualBump
    self.bumpDelay = bumpDelay
    self.neverBumps = neverBumps
  }

  var changeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  private func didWrite() {
    log.record("write")
    guard !neverBumps, !manualBump else { return }
    guard let bumpDelay else {
      bump()
      return
    }
    Task {
      try? await Task.sleep(for: bumpDelay)
      self.bump()
    }
  }

  /// Lets a `manualBump` pasteboard report its change.
  func releaseBump() { bump() }

  private func bump() {
    lock.lock()
    count += 1
    lock.unlock()
    log.record("changed")
  }

  func writeString(_ string: String, forType type: ClipMediaType) { didWrite() }
  func writeData(_ data: Data, forType type: ClipMediaType) { didWrite() }
  func writeRichText(rtf: Data, plain: String) { didWrite() }
  func writeFileURL(_ url: URL) { didWrite() }
}

final class OrderRecordingSynthesizer: EventSynthesizing, @unchecked Sendable {
  private let log: PasteOrderLog
  init(log: PasteOrderLog) { self.log = log }
  func synthesizeCommandV(targeting app: FrontmostAppRef?) throws { log.record("synthesize") }
}

/// Passes bytes through; `RejectingImageNormalizer` models undecodable image data.
struct AcceptingImageNormalizer: ImageNormalizing {
  func normalizedForPaste(_ data: Data) -> (data: Data, mediaType: ClipMediaType)? {
    (data, .png)
  }
}

struct RejectingImageNormalizer: ImageNormalizing {
  func normalizedForPaste(_ data: Data) -> (data: Data, mediaType: ClipMediaType)? { nil }
}

final class SuppressedCounts: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int] = []
  func append(_ count: Int) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(count)
  }
  var values: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

@MainActor
@Suite("PickerViewModel paste ordering (T-PASTEORDER1)")
struct PickerViewModelPasteOrderTests {

  private func makeViewModel(
    ordering: PasteDismissOrdering, log: PasteOrderLog, pasteboard: OrderRecordingPasteboard,
    imageNormalizer: any ImageNormalizing = AcceptingImageNormalizer(),
    blobStore: BlobStore? = nil
  ) -> PickerViewModel {
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: OrderRecordingSynthesizer(log: log),
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding(),
      imageNormalizer: imageNormalizer,
      synthesizesWithoutVerifiedTarget: true)
    let viewModel = makeTestPickerViewModel(
      pasteboard: pasteboard, blobStore: blobStore ?? makeTempBlobStore().blobStore,
      paster: paster, pasteDismissOrdering: ordering)
    viewModel.dismiss = { log.record("dismiss") }
    // A real window is visible while the user picks; the post-write hide is
    // skipped for an already-hidden picker.
    viewModel.willShow()
    return viewModel
  }

  /// `select`/`pasteSnippet` are fire-and-forget; wait for the keystroke.
  private func waitForSynthesis(_ log: PasteOrderLog) async {
    for _ in 0..<300 where !log.events.contains("synthesize") {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("Linux policy: select writes the clipboard BEFORE hiding the picker, then pastes")
  func linuxSelectWritesBeforeDismiss() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(1)), log: log,
      pasteboard: OrderRecordingPasteboard(log: log))

    viewModel.select(makeClipItem(kind: .text, previewText: "picked"))
    await waitForSynthesis(log)

    #expect(log.events == ["write", "changed", "dismiss", "synthesize"])
  }

  @Test("Linux policy: waits for the write to be reported before hiding")
  func linuxWaitsForConfirmation() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(2)), log: log,
      pasteboard: OrderRecordingPasteboard(log: log, bumpDelay: .milliseconds(80)))

    viewModel.select(makeClipItem(kind: .text, previewText: "picked"))
    await waitForSynthesis(log)

    #expect(log.events == ["write", "changed", "dismiss", "synthesize"])
  }

  @Test("Linux policy: an unconfirmed write still hides the picker after the bound")
  func linuxUnconfirmedWriteStillDismisses() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .milliseconds(40)), log: log,
      pasteboard: OrderRecordingPasteboard(log: log, neverBumps: true))

    viewModel.select(makeClipItem(kind: .text, previewText: "picked"))
    await waitForSynthesis(log)

    #expect(log.events == ["write", "dismiss", "synthesize"])
  }

  @Test("Linux policy: pasteSnippet also writes before hiding")
  func linuxSnippetWritesBeforeDismiss() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(1)), log: log,
      pasteboard: OrderRecordingPasteboard(log: log))

    viewModel.pasteSnippet(Snippet(title: "t", body: "snippet body"))
    await waitForSynthesis(log)

    #expect(log.events == ["write", "changed", "dismiss", "synthesize"])
  }

  @Test("macOS policy: select still hides the picker BEFORE writing (unchanged)")
  func macSelectDismissesBeforeWrite() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .dismissBeforeWrite, log: log, pasteboard: OrderRecordingPasteboard(log: log))

    viewModel.select(makeClipItem(kind: .text, previewText: "picked"))
    await waitForSynthesis(log)

    #expect(log.events == ["dismiss", "write", "changed", "synthesize"])
  }

  @Test("macOS policy: pasteSnippet still hides the picker BEFORE writing (unchanged)")
  func macSnippetDismissesBeforeWrite() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .dismissBeforeWrite, log: log, pasteboard: OrderRecordingPasteboard(log: log))

    viewModel.pasteSnippet(Snippet(title: "t", body: "snippet body"))
    await waitForSynthesis(log)

    #expect(log.events == ["dismiss", "write", "changed", "synthesize"])
  }

  @Test("Linux policy: a second Enter during the confirmation window pastes only once")
  func linuxSecondSelectWhilePendingIsIgnored() async {
    let log = PasteOrderLog()
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(2)), log: log,
      pasteboard: OrderRecordingPasteboard(log: log, bumpDelay: .milliseconds(80)))
    let item = makeClipItem(kind: .text, previewText: "picked")

    viewModel.select(item)
    viewModel.select(item)
    viewModel.pasteSnippet(Snippet(title: "t", body: "other"))
    await waitForSynthesis(log)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(log.events == ["write", "changed", "dismiss", "synthesize"])

    // The guard clears on completion: the next paste goes through.
    viewModel.select(item)
    for _ in 0..<300 where log.events.filter({ $0 == "synthesize" }).count < 2 {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(log.events.filter { $0 == "synthesize" }.count == 2)
  }

  @Test("Linux policy: re-arms self-write suppression with the post-bump count, last")
  func linuxRearmsSuppressionWithNewCount() async {
    let log = PasteOrderLog()
    let pasteboard = OrderRecordingPasteboard(log: log, bumpDelay: .milliseconds(60))
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(2)), log: log,
      pasteboard: pasteboard)
    let suppressed = SuppressedCounts()
    viewModel.suppressOwnPasteboardWrite = { suppressed.append($0) }

    viewModel.select(makeClipItem(kind: .text, previewText: "picked"))
    await waitForSynthesis(log)

    // Initial count straight after the write (not yet bumped), then the
    // post-bump count.
    #expect(suppressed.values == [100, 101])
    #expect(suppressed.values.last == pasteboard.changeCount)
  }

  @Test("Linux policy: a paste that throws before writing still closes the picker exactly once")
  func linuxInvalidImageStillDismissesOnce() async throws {
    let log = PasteOrderLog()
    let (directory, blobStore) = makeTempBlobStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobPath = try blobStore.write(Data([0x00, 0x01]))
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(1)), log: log,
      pasteboard: OrderRecordingPasteboard(log: log), imageNormalizer: RejectingImageNormalizer(),
      blobStore: blobStore)

    viewModel.select(makeClipItem(kind: .image, previewText: "img", blobPath: blobPath))
    for _ in 0..<300 where !log.events.contains("dismiss") {
      try? await Task.sleep(for: .milliseconds(10))
    }
    try? await Task.sleep(for: .milliseconds(100))

    #expect(log.events == ["dismiss"])
  }

  @Test("Linux policy: Esc during the confirmation window is not followed by a second hide")
  func linuxAlreadyHiddenPickerIsNotHiddenAgain() async {
    let log = PasteOrderLog()
    let pasteboard = OrderRecordingPasteboard(log: log, manualBump: true)
    let viewModel = makeViewModel(
      ordering: .writeBeforeDismiss(confirmationTimeout: .seconds(2)), log: log,
      pasteboard: pasteboard)

    viewModel.select(makeClipItem(kind: .text, previewText: "picked"))
    // Deterministic: the write has happened, the confirmation is still pending
    // (the bump is held), THEN the picker is hidden, THEN the bump is released.
    for _ in 0..<300 where !log.events.contains("write") {
      try? await Task.sleep(for: .milliseconds(10))
    }
    viewModel.didHide()  // Esc / focus loss while waiting for confirmation
    pasteboard.releaseBump()
    await waitForSynthesis(log)

    #expect(!log.events.contains("dismiss"))
  }
}
