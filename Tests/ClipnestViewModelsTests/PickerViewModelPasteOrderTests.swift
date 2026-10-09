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
/// and `neverBumps` models a compositor that never reports it.
final class OrderRecordingPasteboard: PasteboardWriting, @unchecked Sendable {
  private let log: PasteOrderLog
  private let bumpDelay: Duration?
  private let neverBumps: Bool
  private let lock = NSLock()
  private var count = 100

  init(log: PasteOrderLog, bumpDelay: Duration? = nil, neverBumps: Bool = false) {
    self.log = log
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
    guard !neverBumps else { return }
    guard let bumpDelay else {
      bump()
      return
    }
    Task {
      try? await Task.sleep(for: bumpDelay)
      self.bump()
    }
  }

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

@MainActor
@Suite("PickerViewModel paste ordering (T-PASTEORDER1)")
struct PickerViewModelPasteOrderTests {

  private func makeViewModel(
    ordering: PasteDismissOrdering, log: PasteOrderLog, pasteboard: OrderRecordingPasteboard
  ) -> PickerViewModel {
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: OrderRecordingSynthesizer(log: log),
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding(),
      synthesizesWithoutVerifiedTarget: true)
    let viewModel = makeTestPickerViewModel(
      pasteboard: pasteboard, paster: paster, pasteDismissOrdering: ordering)
    viewModel.dismiss = { log.record("dismiss") }
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
}
