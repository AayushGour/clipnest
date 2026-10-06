// GTKItemRowActionContentTests.swift
//
// Linux parity pass (routed follow-up, 2026-09-06). Exercises
// `ItemRowActions.buttons(for:)`/`.contextMenu(for:)`
// (`Sources/ClipnestGTK/Window/ItemRowActionContent.swift`) — pure gating
// logic, no GTK/display dependency. Pins macOS `ItemRow.swift`'s exact
// parity contract: three always-visible buttons at most (pin/unpin, [save
// as snippet], delete — never "Copy Recognized Text" as a button), and the
// context menu additionally offering "Copy Recognized Text" when present.
import ClipnestCore
import Testing

@testable import ClipnestGTK

@Suite("ItemRowActions")
struct GTKItemRowActionContentTests {
  private func makeItem(
    kind: ItemKind = .text,
    pinned: Bool = false,
    ocrText: String? = nil
  ) -> ClipItem {
    ClipItem(
      kind: kind, previewText: "hello", contentHash: "hash", pinned: pinned,
      sourceAppName: nil, ocrText: ocrText)
  }

  @Test("buttons() for a plain .text item are Pin, Save as Snippet, Delete — in that order")
  func buttonsForTextItem() {
    let entries = ItemRowActions.buttons(for: makeItem(kind: .text))
    #expect(entries.map(\.action) == [.togglePin, .saveAsSnippet, .delete])
  }

  @Test("buttons() never includes Copy Recognized Text, even when the item has recognized text")
  func buttonsNeverIncludeCopyRecognizedText() {
    let entries = ItemRowActions.buttons(for: makeItem(kind: .image, ocrText: "some text"))
    #expect(!entries.map(\.action).contains(.copyRecognizedText))
  }

  @Test(
    "buttons() for a kind that doesn't support Save as Snippet renders exactly two — Pin, Delete — never a dead button"
  )
  func buttonsForUnsupportedKindOmitSaveAsSnippet() {
    for kind: ItemKind in [.richText, .image, .file] {
      let entries = ItemRowActions.buttons(for: makeItem(kind: kind))
      #expect(entries.map(\.action) == [.togglePin, .delete], "kind: \(kind)")
    }
  }

  @Test("Pin/Unpin's label mirrors the item's actual pinned state")
  func pinLabelMirrorsPinnedState() {
    let unpinned = ItemRowActions.buttons(for: makeItem(pinned: false))
    #expect(unpinned.first?.label == "Pin")
    let pinned = ItemRowActions.buttons(for: makeItem(pinned: true))
    #expect(pinned.first?.label == "Unpin")
  }

  @Test("Delete is the only destructive entry, in either surface")
  func onlyDeleteIsDestructive() {
    let item = makeItem(kind: .image, ocrText: "recognized")
    for entry in ItemRowActions.contextMenu(for: item) {
      #expect(entry.isDestructive == (entry.action == .delete))
    }
  }

  @Test(
    "contextMenu() for an image with recognized text is Pin, Copy Recognized Text, Delete — matching ItemRow's gating exactly"
  )
  func contextMenuForImageWithRecognizedText() {
    let entries = ItemRowActions.contextMenu(for: makeItem(kind: .image, ocrText: "text"))
    #expect(entries.map(\.action) == [.togglePin, .copyRecognizedText, .delete])
  }

  @Test(
    "contextMenu() for a .link item is Pin, Save as Snippet, Delete — no Copy Recognized Text (no OCR text on a non-image kind)"
  )
  func contextMenuForLinkItem() {
    let entries = ItemRowActions.contextMenu(for: makeItem(kind: .link))
    #expect(entries.map(\.action) == [.togglePin, .saveAsSnippet, .delete])
  }

  @Test("contextMenu() for an image WITHOUT recognized text has no Copy Recognized Text entry")
  func contextMenuForImageWithoutRecognizedText() {
    let entries = ItemRowActions.contextMenu(for: makeItem(kind: .image, ocrText: nil))
    #expect(!entries.map(\.action).contains(.copyRecognizedText))
  }

  @Test("Every buttons() entry is also present in contextMenu() — the menu is a strict superset")
  func buttonsAreSubsetOfContextMenu() {
    let item = makeItem(kind: .image, ocrText: "text")
    let buttonActions = Set(ItemRowActions.buttons(for: item).map(\.action))
    let menuActions = Set(ItemRowActions.contextMenu(for: item).map(\.action))
    #expect(buttonActions.isSubset(of: menuActions))
  }
}
