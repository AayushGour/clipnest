// LinuxTieredSelectionReplacerTests.swift
//
// T-IBUS-REPLACER: coverage for the composer's fall-through table
// (D-IBUS-1), against fully in-memory mock `SelectionReplacing`
// sub-replacers. The load-bearing assertion throughout is "no double
// insert": once the IBus tier returns a TERMINAL outcome, the clipboard
// tier's `replaceSelection` must be called ZERO times — retrying after a
// real IBus commit reached a live recipient risks a genuine double insert,
// strictly worse than the bug this whole feature exists to fix.

import ClipnestCore
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@MainActor
private final class FakeSelectionReplacing: SelectionReplacing {
  var resultToReturn: SelectionReplaceResult = .noSelection
  private(set) var replaceSelectionCallCount = 0
  private(set) var lastBodyForSelectionResult: String??

  func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    replaceSelectionCallCount += 1
    lastBodyForSelectionResult = await bodyForSelection("probe")
    return resultToReturn
  }
}

@Suite("LinuxTieredSelectionReplacer")
@MainActor
struct LinuxTieredSelectionReplacerTests {
  // MARK: - Fall-through cases: IBus tier tried, clipboard tier ALSO tried

  @Test("IBus .noSelection falls through to the clipboard tier, which runs and its result wins")
  func ibusNoSelectionFallsThroughToClipboard() async {
    let ibus = FakeSelectionReplacing()
    ibus.resultToReturn = .noSelection
    let clipboard = FakeSelectionReplacing()
    clipboard.resultToReturn = .replaced
    let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

    let result = await tiered.replaceSelection(bodyForSelection: { _ in nil })

    #expect(result == .replaced)
    #expect(ibus.replaceSelectionCallCount == 1)
    #expect(clipboard.replaceSelectionCallCount == 1)
  }

  @Test("a permanently-unavailable IBus tier (always .noSelection) always falls through cleanly")
  func permanentlyUnavailableIBusAlwaysFallsThrough() async {
    let ibus = FakeSelectionReplacing()
    ibus.resultToReturn = .noSelection
    let clipboard = FakeSelectionReplacing()
    clipboard.resultToReturn = .noMatch
    let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

    let result = await tiered.replaceSelection(bodyForSelection: { _ in nil })

    #expect(result == .noMatch)
    #expect(clipboard.replaceSelectionCallCount == 1)
  }

  // MARK: - Terminal cases: IBus tier tried, clipboard tier NEVER touched (no double insert)

  @Test(
    "IBus .committedUnconfirmed is TERMINAL — the clipboard tier is NEVER called (no double insert)"
  )
  func ibusCommittedUnconfirmedNeverTouchesClipboardTier() async {
    let ibus = FakeSelectionReplacing()
    ibus.resultToReturn = .committedUnconfirmed
    let clipboard = FakeSelectionReplacing()
    clipboard.resultToReturn = .replaced
    let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

    let result = await tiered.replaceSelection(bodyForSelection: { _ in nil })

    #expect(result == .committedUnconfirmed)
    #expect(ibus.replaceSelectionCallCount == 1)
    #expect(clipboard.replaceSelectionCallCount == 0, "no double insert: clipboard must not run")
  }

  @Test("IBus .noMatch is TERMINAL — the clipboard tier is NEVER called")
  func ibusNoMatchNeverTouchesClipboardTier() async {
    let ibus = FakeSelectionReplacing()
    ibus.resultToReturn = .noMatch
    let clipboard = FakeSelectionReplacing()
    clipboard.resultToReturn = .replaced
    let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

    let result = await tiered.replaceSelection(bodyForSelection: { _ in nil })

    #expect(result == .noMatch)
    #expect(clipboard.replaceSelectionCallCount == 0, "no double insert: clipboard must not run")
  }

  @Test(
    "a hypothetical IBus .replaced (never actually produced, defensive) is ALSO treated as terminal"
  )
  func ibusReplacedIsDefensivelyTerminal() async {
    let ibus = FakeSelectionReplacing()
    ibus.resultToReturn = .replaced
    let clipboard = FakeSelectionReplacing()
    clipboard.resultToReturn = .noMatch
    let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

    let result = await tiered.replaceSelection(bodyForSelection: { _ in nil })

    #expect(result == .replaced)
    #expect(clipboard.replaceSelectionCallCount == 0)
  }

  // MARK: - Every other clipboard-only case is a legitimate fall-through, never terminal at the IBus layer

  @Test(
    "IBus outcomes that are clipboard-specific cases (never actually produced by IBus) still fall through if returned"
  )
  func clipboardSpecificCasesStillFallThroughDefensively() async {
    for outcome: SelectionReplaceResult in [
      .writeUnconfirmed, .copyUnconfirmed, .declinedTerminalTarget,
    ] {
      let ibus = FakeSelectionReplacing()
      ibus.resultToReturn = outcome
      let clipboard = FakeSelectionReplacing()
      clipboard.resultToReturn = .replaced
      let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

      let result = await tiered.replaceSelection(bodyForSelection: { _ in nil })

      #expect(result == .replaced, "outcome \(outcome) should have fallen through")
      #expect(
        clipboard.replaceSelectionCallCount == 1, "outcome \(outcome) should have fallen through")
    }
  }

  // MARK: - bodyForSelection reaches whichever tier actually runs, intact

  @Test("bodyForSelection is passed through to the clipboard tier on fall-through, unmodified")
  func bodyForSelectionReachesClipboardTierOnFallThrough() async {
    let ibus = FakeSelectionReplacing()
    ibus.resultToReturn = .noSelection
    let clipboard = FakeSelectionReplacing()
    clipboard.resultToReturn = .noSelection
    let tiered = LinuxTieredSelectionReplacer(ibusReplacer: ibus, clipboardReplacer: clipboard)

    _ = await tiered.replaceSelection(bodyForSelection: { _ in "Best regards, Clipnest" })

    #expect(ibus.lastBodyForSelectionResult == .some("Best regards, Clipnest"))
    #expect(clipboard.lastBodyForSelectionResult == .some("Best regards, Clipnest"))
  }
}
