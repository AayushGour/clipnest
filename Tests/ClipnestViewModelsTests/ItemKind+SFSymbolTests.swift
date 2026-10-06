// ItemKind+SFSymbolTests.swift
//
// P5 (Phase 3, Linux port): moved from `ClipnestApp` into
// `ClipnestViewModelsTests`. `ItemKind.sfSymbolName` is now `public` (cross-
// module visibility for `ClipnestApp`'s `ItemRow`/`TypeFilterChips` — see
// `ItemKind+SFSymbol.swift`'s doc comment) and `#if os(macOS)`-gated (SF
// Symbols have no Linux equivalent). This whole suite is gated the same way
// — its 7 cases assert exact SF Symbol name strings, which only exist on
// macOS — so it's wrapped in `#if os(macOS)` rather than deleted: unchanged
// bodies/assertions, compiled out entirely on Linux.

import ClipnestCore
import Testing

@testable import ClipnestViewModels

#if os(macOS)
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
#else
  /// New coverage (not part of the 7 moved macOS cases above) for
  /// `gtkIconName` — the Linux counterpart added alongside this move. See
  /// `ItemKind+SFSymbol.swift`'s doc comment.
  @Suite("ItemKind+SFSymbol (gtkIconName)")
  struct ItemKindGTKIconNameTests {

    @Test("Every ItemKind case maps to a non-empty gtkIconName")
    func everyCaseHasANonEmptyIconName() {
      for kind in ItemKind.allCases {
        #expect(!kind.gtkIconName.isEmpty)
      }
    }

    @Test("Every ItemKind case maps to a distinct gtkIconName — no two kinds share an icon")
    func everyCaseHasADistinctIconName() {
      let names = ItemKind.allCases.map(\.gtkIconName)

      #expect(Set(names).count == names.count)
    }
  }
#endif
