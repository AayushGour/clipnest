import ClipnestCore
import Testing

@testable import ClipnestViewModels

@Suite("ItemEditFocusOrder")
struct ItemEditFocusOrderTests {
  private let clip = ClipItem(kind: .text, previewText: "p", contentHash: "h")

  @Test func contentModeFollowsVisualOrder() {
    #expect(
      ItemEditFocusOrder.controls(for: .content(clip), canSave: true)
        == [.bold, .italic, .underline, .editor, .cancel, .save])
  }

  @Test func recognizedTextModeHasNoToolbar() {
    #expect(
      ItemEditFocusOrder.controls(for: .recognizedText(clip), canSave: true)
        == [.editor, .cancel, .save])
  }

  @Test func disabledSaveIsSkipped() {
    #expect(
      ItemEditFocusOrder.controls(for: .content(clip), canSave: false)
        == [.bold, .italic, .underline, .editor, .cancel])
    #expect(
      ItemEditFocusOrder.controls(for: .recognizedText(clip), canSave: false)
        == [.editor, .cancel])
  }

  @Test func identifiersAreUnique() {
    let ids = ItemEditControl.allCases.map(\.rawValue)
    #expect(Set(ids).count == ids.count)
  }

  @Test func shortcutHintsNameTheShortcutPerPlatform() {
    #expect(
      ItemEditStrings.shortcutHint(
        label: ItemEditStrings.boldLabel, key: "B", modifier: ItemEditStrings.macShortcutModifier)
        == "Bold (⌘B)")
    #expect(
      ItemEditStrings.shortcutHint(
        label: ItemEditStrings.underlineLabel, key: "U",
        modifier: ItemEditStrings.linuxShortcutModifier) == "Underline (Ctrl+U)")
  }

  @Test func lossyButtonsHaveDistinctAccessibilityLabels() {
    let saveAnyway = ItemEditStrings.saveAnywayAccessibilityLabel
    #expect(saveAnyway != ItemEditStrings.goBackAccessibilityLabel)
    #expect(saveAnyway.hasPrefix(ItemEditStrings.saveAnyway))
    #expect(ItemEditStrings.goBackAccessibilityLabel.hasPrefix(ItemEditStrings.goBack))
  }
}
