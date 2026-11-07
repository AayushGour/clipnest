import Testing

@testable import ClipnestViewModels

@Suite("SnippetEditFocusOrder")
struct SnippetEditFocusOrderTests {
  @Test func followsVisualOrder() {
    #expect(SnippetEditFocusOrder.controls(canSave: true) == [.tag, .body, .cancel, .save])
  }

  @Test func disabledSaveIsSkipped() {
    #expect(SnippetEditFocusOrder.controls(canSave: false) == [.tag, .body, .cancel])
  }

  @Test func identifiersAreUniqueAndDistinctFromTheItemEditor() {
    let ids = SnippetEditControl.allCases.map(\.rawValue)
    #expect(Set(ids).count == ids.count)
    #expect(Set(ids).isDisjoint(with: ItemEditControl.allCases.map(\.rawValue)))
  }

  @Test func titlesAndLabels() {
    #expect(SnippetEditStrings.title(isNew: true) == "New Snippet")
    #expect(SnippetEditStrings.title(isNew: false) == "Edit Snippet")
    #expect(SnippetEditStrings.tagLabel == "Tag")
    #expect(SnippetEditStrings.bodyLabel == "Body")
  }
}
