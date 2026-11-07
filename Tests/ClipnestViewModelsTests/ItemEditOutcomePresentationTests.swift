import ClipnestCore
import Foundation
import Testing

@testable import ClipnestViewModels

@Suite("ItemEditOutcomePresentation")
struct ItemEditOutcomePresentationTests {
  @Test func savedRefreshesAndCloses() {
    let item = ClipItem(kind: .text, previewText: "a", contentHash: "h")
    let p = ItemEditOutcomePresentation(outcome: .saved(item, clipboard: .notOnClipboard))
    #expect(p.errorMessage == nil)
    #expect(p.refreshList)
    #expect(p.closesEditor)
  }

  @Test func itemGoneShowsMessageStaysOpenAndRefreshesToDropGhostRow() {
    let p = ItemEditOutcomePresentation(outcome: .itemNoLongerExists)
    #expect(p.errorMessage == ItemEditStrings.itemGone)
    #expect(p.refreshList)
    #expect(!p.closesEditor)
  }

  @Test func failedShowsMessageStaysOpenAndRefreshes() {
    let p = ItemEditOutcomePresentation(outcome: .failed(message: "boom"))
    #expect(p.errorMessage == "boom")
    #expect(p.refreshList)
    #expect(!p.closesEditor)
  }
}
