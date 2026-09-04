// FontCoverage.swift
//
// T-GLY1: filters a candidate font-name list down to the ones that
// actually contain a glyph for a given character. Needed because keyboard-
// glyph coverage is uneven across `RandomVariation.glyphCapableFontNames`
// (hand-verified during this spike: e.g. Lucida Grande has no ⏎ glyph, the
// system UI font has no ⇥ glyph) — sampling blind from the full candidate
// list would silently render tofu boxes for some (glyph, font) pairs.

import AppKit
import CoreText

enum FontCoverage {
  static func fontsSupporting(
    _ character: String, from candidates: [String?], pointSize: CGFloat = 24
  ) -> [String?] {
    candidates.filter { fontName in
      let font =
        fontName.flatMap { NSFont(name: $0, size: pointSize) }
        ?? NSFont.systemFont(
          ofSize: pointSize)
      let utf16 = Array(character.utf16)
      guard !utf16.isEmpty else { return false }
      var glyph = CGGlyph()
      return CTFontGetGlyphsForCharacters(font as CTFont, utf16, &glyph, utf16.count)
        && glyph != 0
    }
  }
}
