import AppKit
import Foundation
import Testing

@testable import ClipnestCore

/// Fake `PasteboardWriting` that records what was written instead of touching
/// the real system pasteboard — per coding-standards.md ("never touch
/// `NSPasteboard` from a test").
private final class FakePasteboardWriting: PasteboardWriting, @unchecked Sendable {
  private(set) var writtenString: String?
  private(set) var writtenType: NSPasteboard.PasteboardType?
  private(set) var writtenData: Data?
  private(set) var writtenDataType: NSPasteboard.PasteboardType?
  private(set) var writeCount = 0
  /// Mirrors real `NSPasteboard.changeCount` semantics closely enough for
  /// tests: increments on every write, starting from an arbitrary non-zero
  /// value so `0` never accidentally looks like a legitimate change count.
  private(set) var changeCount = 41

  func writeString(_ string: String, forType type: NSPasteboard.PasteboardType) {
    writtenString = string
    writtenType = type
    writeCount += 1
    changeCount += 1
  }

  func writeData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
    writtenData = data
    writtenDataType = type
    writeCount += 1
    changeCount += 1
  }

  private(set) var writtenRTF: Data?
  private(set) var writtenPlain: String?

  func writeRichText(rtf: Data, plain: String) {
    writtenRTF = rtf
    writtenPlain = plain
    writeCount += 1
    changeCount += 1
  }

  private(set) var writtenFileURL: URL?

  func writeFileURL(_ url: URL) {
    writtenFileURL = url
    writeCount += 1
    changeCount += 1
  }
}

/// Mock `EventSynthesizing` — records invocations instead of posting a real
/// `CGEvent`, per coding-standards.md/spec: "no real key events synthesized in CI."
private final class MockEventSynthesizing: EventSynthesizing, @unchecked Sendable {
  private(set) var invocationCount = 0
  private(set) var lastTarget: FrontmostAppRef?
  var shouldThrow = false
  /// T-HANG2: fired on every real invocation, before `shouldThrow` is
  /// checked — lets `CallOrderRecorder`-based tests prove `onPasteboardWrite`
  /// fires strictly before the synthesized keystroke.
  var onInvoke: (() -> Void)?

  func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
    invocationCount += 1
    lastTarget = app
    onInvoke?()
    if shouldThrow {
      throw PasteError.eventPostFailed
    }
  }
}

/// Records the ORDER in which named events happen across a single
/// `paste()` call — used only by T-HANG2's tests to prove `onPasteboardWrite`
/// fires before the synthesized keystroke, not after `paste()` fully
/// returns. `@unchecked Sendable` matches this file's other fakes: access is
/// always sequential within one `paste()` call, never truly concurrent.
private final class CallOrderRecorder: @unchecked Sendable {
  private(set) var events: [String] = []
  func record(_ event: String) { events.append(event) }
}

/// Fake `FrontmostAppReferenceProviding` — returns a fixed, test-controlled
/// "currently frontmost app" instead of touching real `NSWorkspace` state,
/// per coding-standards.md ("mock side effects... never touch real system
/// state from a test"). Used to exercise `Paster`'s H-1 re-verification
/// (`Paster.isStillFrontmost`) without any real focus change.
private final class FakeFrontmostAppReferenceProviding: FrontmostAppReferenceProviding,
  @unchecked Sendable
{
  var current: FrontmostAppRef?

  init(current: FrontmostAppRef?) {
    self.current = current
  }

  func currentFrontmostAppRef() -> FrontmostAppRef? {
    current
  }
}

@Suite("Paster")
struct PasterTests {
  private let target = FrontmostAppRef(bundleID: "com.apple.TextEdit", processIdentifier: 999)

  /// All the "accessibility granted, target provided" tests below want the
  /// H-1 re-verification to pass (current frontmost == target) so they can
  /// exercise their own scenario in isolation — `stillFrontmostProvider`
  /// reports `target` itself as currently frontmost.
  private var stillFrontmostProvider: FakeFrontmostAppReferenceProviding {
    FakeFrontmostAppReferenceProviding(current: target)
  }

  @Test(
    "With Accessibility granted, writes the pasteboard then calls the synthesizer exactly once with the right target"
  )
  func accessibilityGrantedWritesThenSynthesizes() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider
    )

    try await paster.paste(.text("hello clipboard"), targetingFrontmostApp: target)

    #expect(pasteboard.writtenString == "hello clipboard")
    #expect(pasteboard.writtenType == .string)
    #expect(pasteboard.writeCount == 1)
    #expect(synthesizer.invocationCount == 1)
    #expect(synthesizer.lastTarget == target)
  }

  @Test(
    "Without Accessibility granted, still writes the pasteboard but never calls the synthesizer"
  )
  func accessibilityNotGrantedSkipsSynthesis() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { false },
      synthesisDelay: .zero
    )

    try await paster.paste(.text("clipboard only"), targetingFrontmostApp: target)

    #expect(pasteboard.writtenString == "clipboard only")
    #expect(pasteboard.writeCount == 1)
    #expect(synthesizer.invocationCount == 0)
  }

  @Test(
    "With no frontmost app to target, still writes the pasteboard and skips synthesis even if Accessibility is granted"
  )
  func noTargetSkipsSynthesisEvenWhenGranted() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero
    )

    try await paster.paste(.text("no target"), targetingFrontmostApp: nil)

    #expect(pasteboard.writtenString == "no target")
    #expect(synthesizer.invocationCount == 0)
  }

  @Test("Propagates a genuine PasteError thrown by the synthesizer")
  func propagatesSynthesizerError() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    synthesizer.shouldThrow = true
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider
    )

    await #expect(throws: PasteError.eventPostFailed) {
      try await paster.paste(.text("will fail"), targetingFrontmostApp: target)
    }

    // The pasteboard write still happens before the synthesizer is invoked.
    #expect(pasteboard.writtenString == "will fail")
  }

  @Test(
    "With Accessibility granted, writes valid image bytes as TIFF then calls the synthesizer exactly once with the right target"
  )
  func accessibilityGrantedWritesImageThenSynthesizes() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider
    )
    let validImageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    try await paster.paste(.image(validImageData), targetingFrontmostApp: target)

    #expect(pasteboard.writtenDataType == .tiff)
    #expect(pasteboard.writtenData != nil)
    #expect(synthesizer.invocationCount == 1)
    #expect(synthesizer.lastTarget == target)
  }

  // MARK: - T-PERF1: `.image` decode/re-encode runs off the calling actor

  /// Structural + empirical proof for T-PERF1's directive ("no heavy work on
  /// the main actor") — deliberately NOT a fragile exact-timing assertion.
  /// `paste`'s `.image` case now runs its ImageIO decode/re-encode inside
  /// `Task.detached(priority: .utility)` (see `Paster.paste`'s doc comment).
  /// If it instead ran synchronously on the calling actor (the pre-T-PERF1
  /// behavior — this test would have failed against that code), a
  /// `@MainActor` counter task racing alongside `paste()` could never get
  /// scheduled until `paste()` returned, so it would observe `value == 0`.
  /// Asserting `> 0` (not any specific count) keeps this robust against
  /// machine speed/CI load while still proving genuine interleaving.
  @Test("`.image` decode+re-encode does not block the calling MainActor")
  @MainActor
  func imageDecodeDoesNotBlockTheCallingActor() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { false },
      synthesisDelay: .zero
    )
    // Large enough that ImageIO decode+encode takes measurable time even
    // under a debug (-Onone) build — deterministic synthetic bytes, never a
    // real user file (per coding-standards.md's testing rules).
    let largeImageData = ImageFixtures.makeTinyImageData(width: 2000, height: 2000)

    final class Counter: @unchecked Sendable {
      private(set) var value = 0
      func increment() { value += 1 }
    }
    let counter = Counter()
    let counterTask = Task { @MainActor in
      while !Task.isCancelled {
        counter.increment()
        await Task.yield()
      }
    }
    defer { counterTask.cancel() }

    try await paster.paste(.image(largeImageData), targetingFrontmostApp: nil)

    #expect(counter.value > 0)
    #expect(pasteboard.writtenDataType == .tiff)
  }

  @Test(
    "Image content with undecodable bytes throws invalidImageData, never writes to the pasteboard, and never invokes the synthesizer"
  )
  func invalidImageDataThrowsBeforeAnyWrite() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero
    )
    let invalidImageData = Data([0x00, 0x01, 0x02])

    await #expect(throws: PasteError.invalidImageData) {
      try await paster.paste(.image(invalidImageData), targetingFrontmostApp: target)
    }

    #expect(pasteboard.writtenData == nil)
    #expect(pasteboard.writeCount == 0)
    #expect(synthesizer.invocationCount == 0)
  }

  @Test(
    "With Accessibility granted, writes the file itself then calls the synthesizer exactly once with the right target"
  )
  func accessibilityGrantedWritesFileThenSynthesizes() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider
    )
    let fileURL = URL(fileURLWithPath: "/tmp/example.txt")

    try await paster.paste(.file(fileURL), targetingFrontmostApp: target)

    // Written as a file, via the `writeObjects`-backed path — NOT as a
    // hand-rolled `public.file-url` string, which pasted as literal text in
    // apps reading any other representation.
    #expect(pasteboard.writtenFileURL == fileURL)
    #expect(pasteboard.writtenString == nil)
    #expect(synthesizer.invocationCount == 1)
    #expect(synthesizer.lastTarget == target)
  }

  @Test("Rich text content writes BOTH the RTF and the plain-text representation in one write")
  func richTextWritesBothRepresentations() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider
    )
    let rtf = Data("{\\rtf1\\ansi bold}".utf8)

    try await paster.paste(.richText(rtf: rtf, plain: "bold"), targetingFrontmostApp: target)

    #expect(pasteboard.writtenRTF == rtf)
    #expect(pasteboard.writtenPlain == "bold")
    #expect(pasteboard.writeCount == 1)
    #expect(synthesizer.invocationCount == 1)
  }

  // MARK: - H-1: target-pid re-verification, immediately before posting

  /// `Paster.isStillFrontmost` is pure (no `NSWorkspace`/`CGEvent` call), so
  /// it's tested directly — never posting a real event, per
  /// coding-standards.md.
  @Test("isStillFrontmost matches when the current app's pid equals the target's pid")
  func isStillFrontmostMatchesOnEqualPid() {
    let current = FrontmostAppRef(bundleID: "anything", processIdentifier: target.processIdentifier)
    #expect(Paster.isStillFrontmost(current: current, target: target))
  }

  @Test("isStillFrontmost does not match when the current app's pid differs from the target's pid")
  func isStillFrontmostRejectsDifferentPid() {
    let current = FrontmostAppRef(
      bundleID: target.bundleID, processIdentifier: target.processIdentifier + 1)
    #expect(!Paster.isStillFrontmost(current: current, target: target))
  }

  @Test("isStillFrontmost does not match when there is no current frontmost app")
  func isStillFrontmostRejectsNilCurrent() {
    #expect(!Paster.isStillFrontmost(current: nil, target: target))
  }

  @Test(
    "When a different app has taken focus by the time of posting, paste throws targetNoLongerFrontmost, never invokes the synthesizer, but the pasteboard write still stands"
  )
  func focusStolenBeforePostingSkipsSynthesisAndThrows() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let stealingApp = FrontmostAppRef(
      bundleID: "com.example.Stealer", processIdentifier: target.processIdentifier + 1)
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding(current: stealingApp)
    )

    await #expect(throws: PasteError.targetNoLongerFrontmost) {
      try await paster.paste(.text("sensitive"), targetingFrontmostApp: target)
    }

    // The pasteboard write must still have happened — the user can still
    // paste manually — even though the synthesized keystroke was withheld.
    #expect(pasteboard.writtenString == "sensitive")
    #expect(synthesizer.invocationCount == 0)
  }

  @Test(
    "When focus was stolen by an app that no longer reports as frontmost at all (nil), paste throws targetNoLongerFrontmost and never invokes the synthesizer"
  )
  func noCurrentFrontmostAppBeforePostingSkipsSynthesisAndThrows() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding(current: nil)
    )

    await #expect(throws: PasteError.targetNoLongerFrontmost) {
      try await paster.paste(.text("sensitive"), targetingFrontmostApp: target)
    }

    #expect(pasteboard.writtenString == "sensitive")
    #expect(synthesizer.invocationCount == 0)
  }

  // MARK: - T-HANG2: onPasteboardWrite fires immediately after the write

  /// Regression test for the self-paste-suppression race T-STRESS1's harness
  /// quantified (`.claude/logs/tester.md`, `SelfPasteRaceScenario`: 18/18
  /// raced at 5-42ms against the OLD ordering, where the caller re-read
  /// `pasteboard.changeCount` only after `paste()` had fully returned — i.e.
  /// after `synthesisDelay` + a real event post). Proves the NEW contract by
  /// call ORDER, not wall-clock timing (this file's convention is
  /// `synthesisDelay: .zero`, so a real-time race isn't observable here —
  /// see `SelfPasteRaceScenario`'s own doc comment on why a genuine
  /// wall-clock race lives in `tools/stress-harness` instead, outside
  /// coding-standards.md's "no real timers" `ClipnestCoreTests` rule):
  /// `onPasteboardWrite` must fire strictly BEFORE the synthesized keystroke
  /// is posted, proving it happens before `synthesisDelay`'s sleep and the
  /// H-1 re-verification, not merely "before `paste()` returns."
  ///
  /// Watched this fail first: temporarily moved the `onPasteboardWrite` call
  /// in `Paster.paste` to AFTER `eventSynthesizer.synthesizeCommandV(...)`
  /// (mirroring the OLD `PickerViewModel+Paste.performPaste`'s "arm
  /// suppression only once everything else is done" ordering) — this test
  /// failed with `events == ["synthesized", "wrote:42"]`. Moved the call
  /// back to immediately after the pasteboard write (its real, shipped
  /// position) — passes.
  @Test(
    "onPasteboardWrite fires with the pasteboard's resulting changeCount immediately after the write — strictly before the synthesized keystroke"
  )
  func onPasteboardWriteFiresBeforeSynthesizedKeystroke() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider
    )
    let recorder = CallOrderRecorder()
    synthesizer.onInvoke = { recorder.record("synthesized") }

    try await paster.paste(
      .text("hello"), targetingFrontmostApp: target,
      onPasteboardWrite: { changeCount in
        recorder.record("wrote:\(changeCount)")
      })

    // `FakePasteboardWriting.changeCount` starts at 41 and increments on
    // each write — 42 is the value immediately after this single write.
    #expect(recorder.events == ["wrote:42", "synthesized"])
  }

  @Test(
    "onPasteboardWrite fires for .image content too, after the internal Task.detached decode/re-encode suspension, with the write's real changeCount"
  )
  func onPasteboardWriteFiresForImageContent() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { false },
      synthesisDelay: .zero
    )
    let validImageData = ImageFixtures.makeTinyImageData(width: 4, height: 4)

    final class ObservedChangeCount: @unchecked Sendable {
      var value: Int?
    }
    let observed = ObservedChangeCount()
    try await paster.paste(
      .image(validImageData), targetingFrontmostApp: nil,
      onPasteboardWrite: { changeCount in
        observed.value = changeCount
      })

    #expect(observed.value == pasteboard.changeCount)
    #expect(pasteboard.writtenDataType == .tiff)
  }

  @Test(
    "onPasteboardWrite never fires when invalid image data throws before any write happens"
  )
  func onPasteboardWriteNotCalledWhenWriteNeverHappens() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero
    )
    let invalidImageData = Data([0x00, 0x01, 0x02])

    final class Flag: @unchecked Sendable {
      var called = false
    }
    let flag = Flag()

    await #expect(throws: PasteError.invalidImageData) {
      try await paster.paste(
        .image(invalidImageData), targetingFrontmostApp: target,
        onPasteboardWrite: { _ in flag.called = true })
    }

    #expect(!flag.called)
    #expect(pasteboard.writeCount == 0)
  }
}
