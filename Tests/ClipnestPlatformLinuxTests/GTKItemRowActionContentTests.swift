// GTKItemRowActionContentTests.swift
//
// Linux parity pass (routed follow-up, 2026-09-06). Exercises
// `ItemRowActions.buttons(for:)`/`.contextMenu(for:)`
// (`Sources/ClipnestGTK/Window/ItemRowActionContent.swift`) — pure gating
// logic, no GTK/display dependency. Pins macOS `ItemRow.swift`'s exact
// parity contract: four always-visible buttons at most (pin/unpin, [edit or
// edit recognized text], [save as snippet], delete — never "Copy Recognized
// Text" as a button), and the context menu additionally offering "Copy
// Recognized Text" when present.
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

  @Test("buttons() for a plain .text item are Pin, Edit, Save as Snippet, Delete — in that order")
  func buttonsForTextItem() {
    let entries = ItemRowActions.buttons(for: makeItem(kind: .text))
    #expect(entries.map(\.action) == [.togglePin, .edit, .saveAsSnippet, .delete])
  }

  @Test("buttons() never includes Copy Recognized Text, even when the item has recognized text")
  func buttonsNeverIncludeCopyRecognizedText() {
    let entries = ItemRowActions.buttons(for: makeItem(kind: .image, ocrText: "some text"))
    #expect(!entries.map(\.action).contains(.copyRecognizedText))
  }

  @Test(
    "buttons() for a kind that doesn't support Save as Snippet omit it — .image/.file without OCR text are Pin, Delete and .richText is Pin, Edit, Delete — never a dead button"
  )
  func buttonsForUnsupportedKindOmitSaveAsSnippet() {
    for kind: ItemKind in [.image, .file] {
      let entries = ItemRowActions.buttons(for: makeItem(kind: kind))
      #expect(entries.map(\.action) == [.togglePin, .delete], "kind: \(kind)")
    }
    let rich = ItemRowActions.buttons(for: makeItem(kind: .richText))
    #expect(rich.map(\.action) == [.togglePin, .edit, .delete])
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
    "contextMenu() for an image with recognized text is Pin, Edit Recognized Text, Copy Recognized Text, Delete — matching ItemRow's gating exactly"
  )
  func contextMenuForImageWithRecognizedText() {
    let entries = ItemRowActions.contextMenu(for: makeItem(kind: .image, ocrText: "text"))
    #expect(
      entries.map(\.action) == [.togglePin, .editRecognizedText, .copyRecognizedText, .delete])
  }

  @Test(
    "contextMenu() for a .link item is Pin, Edit, Save as Snippet, Delete — no Copy Recognized Text (no OCR text on a non-image kind)"
  )
  func contextMenuForLinkItem() {
    let entries = ItemRowActions.contextMenu(for: makeItem(kind: .link))
    #expect(entries.map(\.action) == [.togglePin, .edit, .saveAsSnippet, .delete])
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

  @Test func textRichTextAndLinkOfferEditInButtonsAndMenu() {
    for kind: ItemKind in [.text, .richText, .link] {
      let item = makeItem(kind: kind)
      for list in [ItemRowActions.buttons(for: item), ItemRowActions.contextMenu(for: item)] {
        let edit = list.first { $0.action == .edit }
        #expect(edit?.label == "Edit", "kind: \(kind)")
        #expect(!list.map(\.action).contains(.editRecognizedText))
      }
    }
  }

  @Test func imageWithOCROffersEditRecognizedTextAndCopyRecognizedText() {
    let item = makeItem(kind: .image, ocrText: "text")
    let menu = ItemRowActions.contextMenu(for: item)
    #expect(menu.first { $0.action == .editRecognizedText }?.label == "Edit Recognized Text")
    #expect(menu.map(\.action).contains(.copyRecognizedText))
    #expect(!menu.map(\.action).contains(.edit))
    #expect(ItemRowActions.buttons(for: item).map(\.action).contains(.editRecognizedText))
  }

  @Test func fileAndOcrlessImageOfferNoEditEntry() {
    for item in [makeItem(kind: .file), makeItem(kind: .image, ocrText: nil)] {
      let actions =
        ItemRowActions.buttons(for: item).map(\.action)
        + ItemRowActions.contextMenu(for: item).map(\.action)
      #expect(!actions.contains(.edit))
      #expect(!actions.contains(.editRecognizedText))
    }
  }

  @Test func buttonsAndMenuShareTheSameEditEntry() {
    for item in [makeItem(kind: .text), makeItem(kind: .image, ocrText: "t")] {
      let isEdit = { (e: ItemRowActionEntry) in e.action == .edit || e.action == .editRecognizedText
      }
      #expect(
        ItemRowActions.buttons(for: item).filter(isEdit)
          == ItemRowActions.contextMenu(for: item).filter(isEdit))
      #expect(ItemRowActions.buttons(for: item).filter(isEdit).count == 1)
    }
  }
}
