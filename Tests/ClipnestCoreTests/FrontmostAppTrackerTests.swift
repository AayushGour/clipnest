import Foundation
import Testing

@testable import ClipnestCore

private struct FakeFrontmostAppProvider: FrontmostAppReferenceProviding {
  var appRef: FrontmostAppRef?

  func currentFrontmostAppRef() -> FrontmostAppRef? {
    appRef
  }
}

/// A class (not a struct) so a test can mutate what it returns between two
/// `record()` calls, to exercise "last-recorded wins."
private final class MutableFrontmostAppProvider: FrontmostAppReferenceProviding,
  @unchecked Sendable
{
  var appRef: FrontmostAppRef?

  func currentFrontmostAppRef() -> FrontmostAppRef? {
    appRef
  }
}

@Suite("FrontmostAppTracker")
@MainActor
struct FrontmostAppTrackerTests {

  @Test("record() captures the provider's current frontmost app")
  func recordCapturesProvidedApp() {
    let ref = FrontmostAppRef(bundleID: "com.apple.TextEdit", processIdentifier: 1234)
    let tracker = FrontmostAppTracker(provider: FakeFrontmostAppProvider(appRef: ref))

    tracker.record()

    #expect(tracker.consume() == ref)
  }

  @Test("A second record() before consume() overwrites — last-recorded wins")
  func secondRecordOverwritesBeforeConsume() {
    let first = FrontmostAppRef(bundleID: "com.apple.TextEdit", processIdentifier: 1)
    let second = FrontmostAppRef(bundleID: "com.apple.Safari", processIdentifier: 2)
    let provider = MutableFrontmostAppProvider()
    provider.appRef = first
    let tracker = FrontmostAppTracker(provider: provider)

    tracker.record()
    provider.appRef = second
    tracker.record()

    #expect(tracker.consume() == second)
  }

  @Test("consume() returns nil when nothing has been recorded")
  func consumeReturnsNilWhenNothingRecorded() {
    let tracker = FrontmostAppTracker(provider: FakeFrontmostAppProvider(appRef: nil))

    #expect(tracker.consume() == nil)
  }

  @Test("consume() clears the recorded value so a repeat call returns nil")
  func consumeClearsRecordedValue() {
    let ref = FrontmostAppRef(bundleID: "com.apple.TextEdit", processIdentifier: 42)
    let tracker = FrontmostAppTracker(provider: FakeFrontmostAppProvider(appRef: ref))

    tracker.record()
    _ = tracker.consume()

    #expect(tracker.consume() == nil)
  }
}
