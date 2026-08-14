// ItemKind+SFSymbolTests.swift
//
// `ItemKind.sfSymbolName` is already `internal` (no access modifier on the
// extension's computed property), so it's directly reachable via
// `@testable import` — no production visibility change needed for this one.
//
// The `ClipnestApp` *target*'s actual Swift module name is `Clipnest`, not
// `ClipnestApp` — `PRODUCT_NAME: Clipnest` (project.yml) decouples the
// module name from the target name, and Xcode derives the module name from
// `PRODUCT_NAME` when `PRODUCT_MODULE_NAME` isn't set separately. So every
// test file here imports `Clipnest`, matching what the compiler actually
// produces.

import ClipnestCore
import Testing

@testable import Clipnest

@Suite("ItemKind+SFSymbol")
struct ItemKindSFSymbolTests {

  @Test("`.text` maps to the plaintext-document symbol")
  func textMapsToPlaintextSymbol() {
    #expect(ItemKind.text.sfSymbolName == "doc.plaintext")
  }

  @Test("`.richText` maps to the rich-text-document symbol")
  func richTextMapsToRichTextSymbol() {
    #expect(ItemKind.richText.sfSymbolName == "doc.richtext")
  }

  @Test("`.link` maps to the link symbol")
  func linkMapsToLinkSymbol() {
    #expect(ItemKind.link.sfSymbolName == "link")
  }

  @Test("`.image` maps to the photo symbol")
  func imageMapsToPhotoSymbol() {
    #expect(ItemKind.image.sfSymbolName == "photo")
  }

  @Test("`.file` maps to the generic document symbol")
  func fileMapsToDocSymbol() {
    #expect(ItemKind.file.sfSymbolName == "doc")
  }

  @Test("Every ItemKind case maps to a distinct symbol name — no two kinds share an icon")
  func everyCaseHasADistinctSymbolName() {
    let names = ItemKind.allCases.map(\.sfSymbolName)

    #expect(Set(names).count == names.count)
  }

  @Test("Every ItemKind case maps to a non-empty symbol name")
  func everyCaseHasANonEmptySymbolName() {
    for kind in ItemKind.allCases {
      #expect(!kind.sfSymbolName.isEmpty)
    }
  }
}
