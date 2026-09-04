// NotSymbolExtras.swift
//
// T-GLY1: the two `notSymbol` sub-generators that don't fit
// `ImageRenderer.render(_:)`'s "one character, one glyph" shape —
// (1) blank/background-only crops (Vision sometimes returns a bounding box
// over empty space between characters) and (2) partial-character crops cut
// from a run of arbitrary real text (Vision's boxes are not tight, so a
// real crop is often a fragment of one character plus slivers of its
// neighbors, not one full glyph centered and alone). Both reuse
// `ImageRenderer.applyPostEffects`/`pngData` so all of `notSymbol`'s
// sub-generators share one noise/blur post-processing pass.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import GlyphClassifierSupport

enum NotSymbolExtras {
  /// A pure background crop: solid or very-low-noise fill, no glyph at
  /// all. Guards against the classifier learning "background-colored
  /// region -> must contain the glyph it saw most often in training,"
  /// since a real production run WILL sometimes hand it an empty box.
  static func renderBlankCrop(using generator: inout SystemRandomNumberGenerator) -> Data? {
    let size = RandomVariation.canvasPixels(using: &generator)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let (_, background) = RandomVariation.colorPair(using: &generator)
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let cgImage = context.makeImage() else { return nil }

    let spec = RenderSpec(
      character: "", canvasPixels: size, glyphScale: 0, offsetXFraction: 0, offsetYFraction: 0,
      rotationDegrees: 0, foreground: .clear, background: background,
      noiseOpacity: RandomVariation.noiseOpacity(using: &generator),
      blurRadius: RandomVariation.blurRadius(using: &generator), fontName: nil, bold: false)
    let processed = ImageRenderer.applyPostEffects(cgImage, spec: spec)
    return ImageRenderer.pngData(from: processed)
  }

  /// Renders a random word/phrase from `SymbolCatalog.arbitraryWords` full
  /// size, then crops a random sub-window smaller than the full text
  /// bounds — simulating an imprecise Vision bounding box landing on a
  /// fragment of real running text (partial letters, inter-word gaps,
  /// punctuation) rather than one full character.
  static func renderPartialTextCrop(using generator: inout SystemRandomNumberGenerator) -> Data? {
    guard let word = SymbolCatalog.arbitraryWords.randomElement(using: &generator) else {
      return nil
    }
    let fontName = RandomVariation.asciiFontNames.randomElement(using: &generator) ?? nil
    let pointSize = CGFloat.random(in: 18...48, using: &generator)
    let font =
      fontName.flatMap { NSFont(name: $0, size: pointSize) }
      ?? NSFont.systemFont(
        ofSize: pointSize)
    let (foreground, background) = RandomVariation.colorPair(using: &generator)

    let attributed = NSAttributedString(
      string: word, attributes: [.font: font, .foregroundColor: foreground])
    let line = CTLineCreateWithAttributedString(attributed)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let roundedWidth: CGFloat = lineBounds.width.rounded(FloatingPointRoundingRule.up)
    let fullWidth = max(8, Int(roundedWidth) + 16)
    let fullHeight = max(8, Int(pointSize * 1.6))

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let fullContext = CGContext(
        data: nil, width: fullWidth, height: fullHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    fullContext.setFillColor(background.cgColor)
    fullContext.fill(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
    fullContext.textPosition = CGPoint(
      x: 8, y: CGFloat(fullHeight) / 2 - lineBounds.midY)
    CTLineDraw(line, fullContext)
    guard let fullImage = fullContext.makeImage() else { return nil }

    // Crop a sub-window smaller than the full render — this is the
    // "partial character" simulation. Window side length is a fraction of
    // the shorter full-image dimension so it's plausibly glyph-sized, not
    // arbitrarily tiny or as big as the whole word.
    let cropSize = max(
      16,
      Int(CGFloat(min(fullWidth, fullHeight)) * CGFloat.random(in: 0.35...0.8, using: &generator)))
    let maxX = max(1, fullWidth - cropSize)
    let maxY = max(1, fullHeight - cropSize)
    let originX = Int.random(in: 0...maxX, using: &generator)
    let originY = Int.random(in: 0...maxY, using: &generator)
    let cropRect = CGRect(
      x: originX, y: originY, width: min(cropSize, fullWidth - originX),
      height: min(cropSize, fullHeight - originY))
    guard let cropped = fullImage.cropping(to: cropRect) else { return nil }

    let spec = RenderSpec(
      character: word, canvasPixels: cropSize, glyphScale: 0, offsetXFraction: 0,
      offsetYFraction: 0, rotationDegrees: 0, foreground: foreground, background: background,
      noiseOpacity: RandomVariation.noiseOpacity(using: &generator),
      blurRadius: RandomVariation.blurRadius(using: &generator), fontName: fontName, bold: false)
    let processed = ImageRenderer.applyPostEffects(cropped, spec: spec)
    return ImageRenderer.pngData(from: processed)
  }
}
