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

  func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
    invocationCount += 1
    lastTarget = app
    if shouldThrow {
      throw PasteError.eventPostFailed
    }
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
}
