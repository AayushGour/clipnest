import Foundation
import Testing

@testable import ClipnestCore

/// Fake `PasteboardWriting` that records what was written instead of touching
/// the real system pasteboard — per coding-standards.md ("never touch
/// `NSPasteboard` from a test").
///
/// P2-A (Linux port): spelled in terms of `ClipMediaType` (not
/// `NSPasteboard.PasteboardType` directly, which `PasteboardWriting` itself
/// never required) — the exact same type on macOS, so this drops the need
/// for `import AppKit` in this file without changing behavior there.
private final class FakePasteboardWriting: PasteboardWriting, @unchecked Sendable {
  private(set) var writtenString: String?
  private(set) var writtenType: ClipMediaType?
  private(set) var writtenData: Data?
  private(set) var writtenDataType: ClipMediaType?
  private(set) var writeCount = 0
  /// Mirrors real `NSPasteboard.changeCount` semantics closely enough for
  /// tests: increments on every write, starting from an arbitrary non-zero
  /// value so `0` never accidentally looks like a legitimate change count.
  private(set) var changeCount = 41

  func writeString(_ string: String, forType type: ClipMediaType) {
    writtenString = string
    writtenType = type
    writeCount += 1
    changeCount += 1
  }

  func writeData(_ data: Data, forType type: ClipMediaType) {
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

  func synthesizeCommandV(targeting app: FrontmostAppRef?) throws {
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

/// Fake `ImageNormalizing` — records the bytes it was asked to normalize and
/// returns a fixed, test-controlled result instead of doing any real
/// decode/encode. Doubles as the executable contract spec `ImageNormalizing`
/// implementations (macOS's `MacImageNormalizer`, and a future Linux
/// backend) must satisfy: `Paster` passes `.image` bytes straight through
/// and writes back exactly whatever `(data, mediaType)` comes out, or treats
/// `nil` as `PasteError.invalidImageData` thrown before any pasteboard
/// write — see `pasterUsesInjectedImageNormalizer` and
/// `pasterThrowsInvalidImageDataWhenInjectedNormalizerReturnsNil` below.
/// `@unchecked Sendable` matches this file's other fakes: `paste()` awaits
/// its `Task.detached` internally before returning, so by the time a test
/// reads `receivedData` there is no concurrent access left.
private final class FakeImageNormalizing: ImageNormalizing, @unchecked Sendable {
  private(set) var receivedData: Data?
  private let result: (data: Data, mediaType: ClipMediaType)?

  init(result: (data: Data, mediaType: ClipMediaType)?) {
    self.result = result
  }

  func normalizedForPaste(_ data: Data) -> (data: Data, mediaType: ClipMediaType)? {
    receivedData = data
    return result
  }
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

  // MARK: - T-WLPASTE-NIL1: synthesizesWithoutVerifiedTarget

  @Test(
    "With Accessibility granted, no target, and synthesizesWithoutVerifiedTarget true, synthesizes targeting nil instead of skipping"
  )
  func noTargetStillSynthesizesWhenUnverifiedTargetAllowed() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      synthesizesWithoutVerifiedTarget: true
    )

    try await paster.paste(.text("no verified target"), targetingFrontmostApp: nil)

    #expect(pasteboard.writtenString == "no verified target")
    #expect(synthesizer.invocationCount == 1)
    #expect(synthesizer.lastTarget == nil)
  }

  @Test(
    "Without Accessibility granted, synthesizesWithoutVerifiedTarget true still never calls the synthesizer"
  )
  func unverifiedTargetAllowedNeverOverridesAccessibilityGate() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { false },
      synthesisDelay: .zero,
      synthesizesWithoutVerifiedTarget: true
    )

    try await paster.paste(.text("still clipboard only"), targetingFrontmostApp: nil)

    #expect(pasteboard.writtenString == "still clipboard only")
    #expect(synthesizer.invocationCount == 0)
  }

  @Test(
    "With a verified target, synthesizesWithoutVerifiedTarget true does not change the verified-target path — H-1 still applies"
  )
  func verifiedTargetPathUnaffectedByUnverifiedTargetFlag() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: stillFrontmostProvider,
      synthesizesWithoutVerifiedTarget: true
    )

    try await paster.paste(.text("verified"), targetingFrontmostApp: target)

    #expect(synthesizer.invocationCount == 1)
    #expect(synthesizer.lastTarget == target)
  }

  @Test(
    "With a verified target that is no longer frontmost, synthesizesWithoutVerifiedTarget true still throws targetNoLongerFrontmost rather than falling back to an unverified post"
  )
  func verifiedTargetStolenStillThrowsEvenWhenUnverifiedTargetAllowed() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let stealingApp = FrontmostAppRef(
      bundleID: "com.example.Stealer", processIdentifier: target.processIdentifier + 1)
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { true },
      synthesisDelay: .zero,
      frontmostAppProvider: FakeFrontmostAppReferenceProviding(current: stealingApp),
      synthesizesWithoutVerifiedTarget: true
    )

    await #expect(throws: PasteError.targetNoLongerFrontmost) {
      try await paster.paste(.text("sensitive"), targetingFrontmostApp: target)
    }

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

  #if os(macOS)
    // P2-A (Linux port): this test never injects an `imageNormalizer:`, so
    // `Paster` falls back to its default — `PlatformDefaults.imageNormalizer`
    // — which is the real, Apple-only `MacImageNormalizer` (TIFF re-encode)
    // on macOS but a portable `NoOpImageNormalizer` (always `nil`) off it
    // (see `Paster.swift`'s `#if !os(macOS)` section). On Linux this would
    // throw `PasteError.invalidImageData` before ever reaching the
    // `.tiff`/`writtenData` assertions below, not merely assert something
    // different — genuinely exercising the Apple default, not this seam's
    // portable contract (which `pasterUsesInjectedImageNormalizer` below
    // already covers on every platform). macOS-only, not file-wide.
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
  #endif

  // MARK: - T-PERF4: `.image` decode/re-encode running off the calling actor
  // is NOT unit-testable here — see below for why, and what to do instead.
  //
  // This suite used to carry `imageDecodeDoesNotBlockTheCallingActor`, which
  // raced a `@MainActor` counter task against `paster.paste(.image(...))`
  // and asserted `counter.value > 0` as "proof" the decode didn't block the
  // caller (originally written for T-PERF1). It was deleted (T-PERF4)
  // because it is structurally incapable of failing, regardless of what the
  // production implementation actually does:
  //
  // `Paster.paste` is a `nonisolated async` method on a non-actor struct.
  // Per SE-0338, ANY call to a nonisolated async function from an actor-
  // isolated context (here, the test's own `@MainActor` func) hops off that
  // actor at the `await` call site itself, before a single line of the
  // callee's body runs — independent of whether the callee then does its
  // work via `Task.detached`, inline, or any other means. That entry hop
  // alone frees the MainActor to keep running `counterTask`'s loop for the
  // full duration of `paste()`, so `counter.value > 0` was guaranteed true
  // even with the `.image` case's `Task.detached(priority: .utility)`
  // offload (the actual T-PERF1 fix, see `Paster.paste`'s `.image` case)
  // removed entirely and the decode called synchronously inline instead.
  //
  // Proved empirically, not just argued: `Task.detached` was temporarily
  // deleted from `Paster.paste`'s `.image` case (decode called directly,
  // inline, no detached child task) and this test was re-run against that
  // reverted code — it still passed. The production file was restored
  // immediately after with `git checkout --`, and `git diff`/`git status`
  // confirmed it was byte-identical to HEAD afterward. See
  // `.claude/logs/senior-dev.md` (T-PERF4) for the pasted command output of
  // both the reverted (still-passing) run and the restored run.
  //
  // What is genuinely NOT covered as a result: whether the `.image` decode
  // actually runs via `Task.detached(priority: .utility)` (a separate,
  // lower-priority child task) versus synchronously inline within
  // `paste()`'s own already-off-actor frame. That distinction matters for
  // real-world cooperative-thread-pool contention/priority inversion under
  // load — NOT for "does it block the caller's actor," which is trivially
  // guaranteed by nonisolation itself. Nothing in `Paster`'s injectable
  // surface (`PasteboardWriting`, `EventSynthesizing`,
  // `FrontmostAppReferenceProviding`, `isAccessibilityGranted`) sits
  // anywhere near the decode step, so there is no seam this test file can
  // hook without a production-side change (e.g. an injectable decode
  // executor/clock) — out of scope for this fix, since production source
  // ownership for `Paster.swift` sits elsewhere. If that guarantee needs a
  // regression test, it belongs at the same level T-STRESS1's self-paste
  // race lives at — `tools/stress-harness` — which can make real
  // wall-clock/thread-pool observations that a deterministic
  // `ClipnestCoreTests` unit test structurally cannot (see the T-HANG2
  // comment on `onPasteboardWriteFiresBeforeSynthesizedKeystroke` below for
  // why THAT property is asserted by call order here instead of timing, and
  // why a genuine wall-clock race for it also lives outside this file).
  //
  // `accessibilityGrantedWritesImageThenSynthesizes` above still covers the
  // functional contract (valid `.image` bytes are decoded, re-encoded as
  // TIFF, and written) — that part was never in question.

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

  // MARK: - ImageNormalizing contract (Linux port prep)
  //
  // `accessibilityGrantedWritesImageThenSynthesizes` above already covers
  // the DEFAULT wiring (real `MacImageNormalizer` on macOS, via
  // `PlatformDefaults.imageNormalizer`). These two tests instead inject a
  // `FakeImageNormalizing` to pin the SEAM's contract itself, independent of
  // any one implementation — the executable spec a future Linux
  // `ImageNormalizing` backend must also satisfy.

  @Test(
    "Paster passes .image bytes straight to the injected ImageNormalizing and writes back exactly what it returns, under the mediaType it returns"
  )
  func pasterUsesInjectedImageNormalizer() async throws {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let sourceBytes = Data([0x00, 0x01])
    let normalizedBytes = Data([0xAB, 0xCD, 0xEF])
    let normalizer = FakeImageNormalizing(result: (normalizedBytes, .png))
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { false },
      synthesisDelay: .zero,
      imageNormalizer: normalizer
    )

    try await paster.paste(.image(sourceBytes), targetingFrontmostApp: nil)

    #expect(normalizer.receivedData == sourceBytes)
    #expect(pasteboard.writtenData == normalizedBytes)
    #expect(pasteboard.writtenDataType == .png)
  }

  @Test(
    "Paster throws invalidImageData before any pasteboard write when the injected ImageNormalizing returns nil"
  )
  func pasterThrowsInvalidImageDataWhenInjectedNormalizerReturnsNil() async {
    let pasteboard = FakePasteboardWriting()
    let synthesizer = MockEventSynthesizing()
    let normalizer = FakeImageNormalizing(result: nil)
    let paster = Paster(
      pasteboard: pasteboard,
      eventSynthesizer: synthesizer,
      isAccessibilityGranted: { false },
      synthesisDelay: .zero,
      imageNormalizer: normalizer
    )

    await #expect(throws: PasteError.invalidImageData) {
      try await paster.paste(.image(Data([0xFF])), targetingFrontmostApp: nil)
    }

    #expect(normalizer.receivedData == Data([0xFF]))
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

  #if os(macOS)
    // P2-A (Linux port): same reason as `accessibilityGrantedWritesImageThenSynthesizes`
    // above — no `imageNormalizer:` injected, so this exercises the real
    // Apple-only `MacImageNormalizer` default (`.tiff` re-encode), which
    // doesn't exist off macOS.
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
  #endif

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
