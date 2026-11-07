import Testing

@testable import ClipnestGTK

@Suite("EditorKeyAction")
struct GTKEditorKeyActionTests {
  private let ctrl = KeyEventMapping.controlMask
  private let shift = KeyEventMapping.shiftMask
  private let alt = KeyEventMapping.altMask
  private let escape: UInt32 = 0xff1b
  private let enter: UInt32 = 0xff0d
  private let kpEnter: UInt32 = 0xff8d
  private let tab: UInt32 = 0xff09

  private func action(
    _ keyval: UInt32, _ state: UInt32 = 0, inEditor: Bool = true, rich: Bool = true
  ) -> EditorKeyAction? {
    EditorKeyAction.action(
      keyval: keyval, state: state, focusInEditor: inEditor, isRichText: rich)
  }

  @Test func escapeCancelsFromAnywhere() {
    #expect(action(escape, inEditor: false) == .cancel)
    #expect(action(escape, inEditor: true) == .cancel)
    #expect(action(escape, ctrl) == nil)
  }

  @Test func ctrlReturnSavesPlainReturnDoesNot() {
    #expect(action(enter, ctrl, inEditor: true) == .save)
    #expect(action(enter, ctrl, inEditor: false) == .save)
    #expect(action(kpEnter, ctrl) == .save)
    // Plain Return: newline in the editor / default button elsewhere (GTK's job).
    #expect(action(enter) == nil)
    #expect(action(enter, ctrl | alt) == nil)
  }

  @Test func ctrlTabInsertsTabOnlyInTheEditor() {
    #expect(action(tab, ctrl, inEditor: true) == .insertTab)
    #expect(action(tab, ctrl, inEditor: false) == nil)
    #expect(action(tab, ctrl | shift) == nil)
    #expect(action(tab) == nil)
  }

  @Test func ctrlBIUToggleFormattingInTheRichEditor() {
    #expect(action(0x62, ctrl) == .toggleBold)
    #expect(action(0x42, ctrl | KeyEventMapping.lockMask) == .toggleBold)
    #expect(action(0x69, ctrl) == .toggleItalic)
    #expect(action(0x75, ctrl) == .toggleUnderline)
    // Caps Lock on: uppercase keyval, still underline.
    #expect(action(0x55, ctrl | KeyEventMapping.lockMask) == .toggleUnderline)
    // Ctrl+Shift+U is IBus Unicode input: never swallowed.
    #expect(action(0x55, ctrl | shift) == nil)
    #expect(action(0x75, ctrl | shift) == nil)
    #expect(action(escape, shift) == nil)
    #expect(action(0x62) == nil)
    #expect(action(0x62, ctrl, inEditor: false) == nil)
    #expect(action(0x62, ctrl, rich: false) == nil)
  }

  /// The snippet editor (plain-text Body, `isRichText: false`): Esc, Ctrl+Return
  /// and Ctrl+Tab behave as in the item editor, formatting chords do nothing.
  @Test func snippetEditorKeepsNavigationChordsAndDropsFormatting() {
    #expect(action(escape, rich: false) == .cancel)
    #expect(action(enter, ctrl, inEditor: false, rich: false) == .save)
    #expect(action(enter, ctrl, inEditor: true, rich: false) == .save)
    #expect(action(tab, ctrl, inEditor: true, rich: false) == .insertTab)
    #expect(action(tab, ctrl, inEditor: false, rich: false) == nil)
    #expect(action(enter, inEditor: true, rich: false) == nil)
    for key: UInt32 in [0x62, 0x69, 0x75, 0x42, 0x49, 0x55] {
      #expect(action(key, ctrl, inEditor: true, rich: false) == nil)
    }
  }
}
