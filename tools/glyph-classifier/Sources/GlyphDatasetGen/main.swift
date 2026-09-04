// main.swift
//
// T-GLY1 dataset generator. Run from `tools/glyph-classifier/`:
//   swift run GlyphDatasetGen
// Writes `dataset/{train,test}/<classID>/*.png` (gitignored — see repo-root
// .gitignore's T-GLY1 section) using `SymbolCatalog`'s class list and
// `ImageRenderer`/`RandomVariation` for the actual pixels. Every count
// below is a `static let` — no magic numbers scattered through the
// generation loops (coding-standards.md's Non-negotiables, applied to this
// tooling too even though it never ships).

import AppKit
import Foundation
import GlyphClassifierSupport

enum GenConfig {
  /// Per keyboard-glyph class. Glyphs are a closed, hand-curated set of 9
  /// distinct shapes with real font-glyph backing (not procedurally
  /// generated text), so a moderate per-class count plus this renderer's
  /// heavy scale/position/color/font jitter is enough to cover realistic
  /// visual variety without an excessive generation/training time.
  static let glyphTrainCount = 220
  static let glyphTestCount = 50

  /// Per emoji class. Lower than glyphs' per-class count: emoji rendering
  /// has only one real visual source (Apple Color Emoji — font choice is
  /// irrelevant, see `RenderSpec.fontName`'s doc comment), so canvas
  /// size/crop-looseness/color-background jitter is the only real source
  /// of variety per class; more samples would mostly be near-duplicates.
  static let emojiTrainCount = 110
  static let emojiTestCount = 25

  /// `notSymbol` is deliberately the largest class by a wide margin — see
  /// `SymbolCatalog.notSymbolClassID`'s doc comment for why (a false
  /// positive here is worse than a missed glyph). Split across four
  /// sub-generators by `notSymbolMix` below.
  static let notSymbolTrainCount = 4_000
  static let notSymbolTestCount = 800

  /// Fraction of `notSymbol` samples drawn from each sub-generator —
  /// must sum to 1.0. Confusables (the exact characters Vision actually
  /// misread a keyboard glyph as, per this spike's benchmark) are
  /// oversampled relative to their share of the full ASCII alphabet
  /// (9 confusable characters vs. ~89 general ASCII characters) precisely
  /// because they are the highest-risk false-positive source.
  static let notSymbolMix:
    (generalASCII: Double, confusable: Double, partialText: Double, blank: Double) = (
      0.40, 0.25, 0.20, 0.15
    )
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  .appendingPathComponent("dataset")
let writer = DatasetWriter(rootURL: root)
var rng = SystemRandomNumberGenerator()

print("T-GLY1 dataset generator writing to \(root.path)")

// MARK: - Keyboard glyphs

@MainActor
func makeGlyphSpec(character: String, fontName: String?) -> RenderSpec {
  // Exactly one `colorPair` draw — foreground/background must come from
  // the SAME pair (a coherent light/dark/low-contrast combination), not
  // two independent draws that could pair a dark-mode foreground with a
  // light-mode background.
  let colors = RandomVariation.colorPair(using: &rng)
  return RenderSpec(
    character: character,
    canvasPixels: RandomVariation.canvasPixels(using: &rng),
    glyphScale: RandomVariation.glyphScale(using: &rng),
    offsetXFraction: RandomVariation.offsetFraction(using: &rng),
    offsetYFraction: RandomVariation.offsetFraction(using: &rng),
    rotationDegrees: RandomVariation.rotationDegrees(using: &rng),
    foreground: colors.foreground,
    background: colors.background,
    noiseOpacity: RandomVariation.noiseOpacity(using: &rng),
    blurRadius: RandomVariation.blurRadius(using: &rng),
    fontName: fontName,
    bold: RandomVariation.bold(using: &rng)
  )
}

@MainActor
func generateKeyboardGlyphs() throws {
  for glyph in SymbolCatalog.keyboardGlyphs {
    let validFonts = FontCoverage.fontsSupporting(
      glyph.character, from: RandomVariation.glyphCapableFontNames)
    guard !validFonts.isEmpty else {
      print("WARNING: no font covers glyph \(glyph.id) (\(glyph.character)) — skipping class")
      continue
    }
    let total = GenConfig.glyphTrainCount + GenConfig.glyphTestCount
    var written = 0
    for i in 0..<total {
      let fontName = validFonts.randomElement(using: &rng) ?? nil
      let spec = makeGlyphSpec(character: glyph.character, fontName: fontName)
      guard let data = ImageRenderer.render(spec) else { continue }
      let split: DatasetSplit = i < GenConfig.glyphTrainCount ? .train : .test
      try writer.write(data, classID: glyph.id, split: split, index: i)
      written += 1
    }
    print("glyph \(glyph.id): wrote \(written)/\(total)")
  }
}

// MARK: - Emoji

@MainActor
func generateEmoji() throws {
  for emoji in SymbolCatalog.emojiSubset {
    let total = GenConfig.emojiTrainCount + GenConfig.emojiTestCount
    var written = 0
    for i in 0..<total {
      // fontName always nil: Apple Color Emoji is substituted via Core
      // Text's cascade regardless of requested font (see RenderSpec's doc
      // comment) — real variety here comes from canvas size / crop
      // looseness / background color, not font choice.
      let spec = makeGlyphSpec(character: emoji.character, fontName: nil)
      guard let data = ImageRenderer.render(spec) else { continue }
      let split: DatasetSplit = i < GenConfig.emojiTrainCount ? .train : .test
      try writer.write(data, classID: emoji.id, split: split, index: i)
      written += 1
    }
    print("emoji \(emoji.id): wrote \(written)/\(total)")
  }
}

// MARK: - notSymbol

enum NotSymbolKind {
  case generalASCII
  case confusable
  case partialText
  case blank
}

@MainActor
func pickNotSymbolKind() -> NotSymbolKind {
  let roll = Double.random(in: 0...1, using: &rng)
  let mix = GenConfig.notSymbolMix
  if roll < mix.generalASCII { return .generalASCII }
  if roll < mix.generalASCII + mix.confusable { return .confusable }
  if roll < mix.generalASCII + mix.confusable + mix.partialText { return .partialText }
  return .blank
}

@MainActor
func generateNotSymbol() throws {
  let total = GenConfig.notSymbolTrainCount + GenConfig.notSymbolTestCount
  var written = 0
  for i in 0..<total {
    let data: Data?
    switch pickNotSymbolKind() {
    case .generalASCII:
      guard let character = SymbolCatalog.asciiAlphabet.randomElement(using: &rng) else {
        data = nil
        break
      }
      let validFonts = FontCoverage.fontsSupporting(
        character, from: RandomVariation.asciiFontNames)
      let fontName = (validFonts.isEmpty ? [nil] : validFonts).randomElement(using: &rng) ?? nil
      data = ImageRenderer.render(makeGlyphSpec(character: character, fontName: fontName))
    case .confusable:
      guard let character = SymbolCatalog.confusableCharacters.randomElement(using: &rng) else {
        data = nil
        break
      }
      let validFonts = FontCoverage.fontsSupporting(
        character, from: RandomVariation.asciiFontNames)
      let fontName = (validFonts.isEmpty ? [nil] : validFonts).randomElement(using: &rng) ?? nil
      data = ImageRenderer.render(makeGlyphSpec(character: character, fontName: fontName))
    case .partialText:
      data = NotSymbolExtras.renderPartialTextCrop(using: &rng)
    case .blank:
      data = NotSymbolExtras.renderBlankCrop(using: &rng)
    }
    guard let data else { continue }
    let split: DatasetSplit = i < GenConfig.notSymbolTrainCount ? .train : .test
    try writer.write(data, classID: notSymbolClassID, split: split, index: i)
    written += 1
    if written % 500 == 0 { print("notSymbol: \(written)/\(total)") }
  }
  print("notSymbol: wrote \(written)/\(total)")
}

// MARK: - Run

do {
  try generateKeyboardGlyphs()
  try generateEmoji()
  try generateNotSymbol()
  print("Dataset generation complete.")
} catch {
  print("FATAL: dataset generation failed: \(error)")
  exit(1)
}
