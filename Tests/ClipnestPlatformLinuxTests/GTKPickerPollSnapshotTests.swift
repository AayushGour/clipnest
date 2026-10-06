// GTKPickerPollSnapshotTests.swift
//
// P7-D (Linux port, GTK4 view layer): exercises
// `PickerPollSnapshot.changedAspects(from:to:)` — the entire decision of
// what `PickerWindow`'s poll loop re-renders each tick (see
// `PickerPollSnapshot.swift`'s top doc comment for why polling exists at
// all on Linux). See GTKKeyEventMappingTests.swift's top doc comment for
// the `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency
// note that applies to every `GTK*Tests.swift` file.
import ClipnestCore
import ClipnestViewModels
import Testing

@testable import ClipnestGTK

@Suite("PickerPollSnapshot")
struct GTKPickerPollSnapshotTests {
  private func item(_ text: String = "x") -> ClipItem {
    ClipItem(kind: .text, previewText: text, contentHash: text)
  }

  @Test("Two identical snapshots change nothing")
  func identicalSnapshotsChangeNothing() {
    let snapshot = PickerPollSnapshot.initial
    #expect(PickerPollSnapshot.changedAspects(from: snapshot, to: snapshot).isEmpty)
  }

  @Test("The very first tick (diffed against .initial) reports .rows when rows differ")
  func firstTickReportsRows() {
    var next = PickerPollSnapshot.initial
    next.rows = [item()]
    let aspects = PickerPollSnapshot.changedAspects(from: .initial, to: next)
    #expect(aspects.contains(.rows))
    #expect(!aspects.contains(.snippets))
  }

  @Test("Switching tabs reports BOTH .rows and .snippets, even if the arrays are unchanged")
  func tabSwitchReportsBothListAspects() {
    var old = PickerPollSnapshot.initial
    old.activeTab = .history
    var next = old
    next.activeTab = .snippets
    let aspects = PickerPollSnapshot.changedAspects(from: old, to: next)
    #expect(aspects.contains(.rows))
    #expect(aspects.contains(.snippets))
  }

  @Test("Selection change reports only .selection")
  func selectionChangeIsIsolated() {
    let id = ClipItem.ID()
    var old = PickerPollSnapshot.initial
    old.rows = [item()]
    var next = old
    next.selectedItemID = id
    let aspects = PickerPollSnapshot.changedAspects(from: old, to: next)
    #expect(aspects == [.selection])
  }

  @Test("Each token bump reports exactly its own aspect")
  func tokenBumpsAreIsolated() {
    let base = PickerPollSnapshot.initial

    var focusChanged = base
    focusChanged.focusToken += 1
    #expect(PickerPollSnapshot.changedAspects(from: base, to: focusChanged) == [.focus])

    var scrollChanged = base
    scrollChanged.scrollToTopToken += 1
    #expect(PickerPollSnapshot.changedAspects(from: base, to: scrollChanged) == [.scrollToTop])

    var searchResetChanged = base
    searchResetChanged.searchResetToken += 1
    #expect(
      PickerPollSnapshot.changedAspects(from: base, to: searchResetChanged) == [.searchReset])

    var searchingChanged = base
    searchingChanged.isSearching = true
    #expect(PickerPollSnapshot.changedAspects(from: base, to: searchingChanged) == [.searching])

    var previewChanged = base
    previewChanged.previewTargetID = ClipItem.ID()
    #expect(PickerPollSnapshot.changedAspects(from: base, to: previewChanged) == [.preview])
  }

  @Test("Multiple simultaneous changes are all reported together")
  func multipleChangesAllReported() {
    var next = PickerPollSnapshot.initial
    next.isSearching = true
    next.focusToken += 1
    let aspects = PickerPollSnapshot.changedAspects(from: .initial, to: next)
    #expect(aspects == [.searching, .focus])
  }
}
