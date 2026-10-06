// GTKPickerRowsAppendTests.swift
//
// P10-D (Linux port, GTK4 view layer): exercises
// `PickerWindow.appendedSuffixStart(old:new:)` — the pure decision behind
// `PickerWindow+Rows.swift`'s `updateRows`/`updateSnippetRows`: whether a
// row-list change is pure growth off the end (pagination's
// `loadMoreIfNeeded()`, safe to render as an incremental `listBox` append)
// or anything else (safe only as the existing full teardown+rebuild). See
// `appendedSuffixStart`'s doc comment for the exact shapes it does and does
// not consider append-safe. See `GTKKeyEventMappingTests.swift`'s top doc
// comment for this module's shared `ClipnestPlatformLinuxTests` ->
// `ClipnestGTK` manifest-dependency note.
import Testing

@testable import ClipnestGTK

@Suite("PickerWindow.appendedSuffixStart")
struct GTKPickerRowsAppendTests {
  @Test("new rows appended after the existing ones is append-safe")
  func pureGrowthIsAppendSafe() {
    let old = [1, 2, 3]
    let new = [1, 2, 3, 4, 5]
    #expect(PickerWindow.appendedSuffixStart(old: old, new: new) == 3)
  }

  @Test("identical arrays are not append-safe (nothing to append)")
  func noGrowthIsNotAppendSafe() {
    let old = [1, 2, 3]
    let new = [1, 2, 3]
    #expect(PickerWindow.appendedSuffixStart(old: old, new: new) == nil)
  }

  @Test("a shrinking list is not append-safe")
  func shrinkingIsNotAppendSafe() {
    let old = [1, 2, 3, 4]
    let new = [1, 2, 3]
    #expect(PickerWindow.appendedSuffixStart(old: old, new: new) == nil)
  }

  @Test("a new item PREPENDED (e.g. a fresh capture landing) is not append-safe")
  func prependIsNotAppendSafe() {
    let old = [2, 3, 4]
    let new = [1, 2, 3, 4]
    #expect(PickerWindow.appendedSuffixStart(old: old, new: new) == nil)
  }

  @Test("a reorder (e.g. pin/unpin) is not append-safe even at the same length + 1")
  func reorderIsNotAppendSafe() {
    let old = [1, 2, 3]
    let new = [3, 1, 2, 4]
    #expect(PickerWindow.appendedSuffixStart(old: old, new: new) == nil)
  }

  @Test("an empty old list growing from zero is append-safe")
  func growthFromEmptyIsAppendSafe() {
    let old: [Int] = []
    let new = [1, 2]
    #expect(PickerWindow.appendedSuffixStart(old: old, new: new) == 0)
  }
}
