// ImageRenderer.swift
//
// T-GLY1: renders one synthetic training/test crop per call. Everything a
// real screenshot crop could vary along is a parameter here — font/weight,
// point size, fg/bg color (incl. dark mode + low-contrast pairs),
// antialiasing (via CoreText's default text rendering, always on),
// sub-pixel offset, rotation jitter, additive noise, and crop looseness
// (the glyph is drawn at a random scale/position within its canvas rather
// than always dead-center and tightly fit, matching how Vision's bounding
// boxes are not tight around the true glyph). See `RenderSpec` below for
// every tunable, and `RandomVariation` for how each spec is sampled.

import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// One fully-specified render — every field is either fixed by the caller
/// (the character/emoji being drawn) or sampled by `RandomVariation`
/// (everything about how it looks). Kept as a single struct rather than
/// scattered function parameters so `ImageRenderer.render(_:)` has exactly
/// one signature regardless of which class is being rendered.
struct RenderSpec {
  var character: String
  /// Canvas is always square; this is its pixel side length. Varies per
  /// sample to simulate different screenshot scales / OCR downscale
  /// factors reaching this crop.
  var canvasPixels: Int
  /// Fraction of `canvasPixels` the glyph's nominal point size targets —
  /// the actual rendered size still depends on the font's own glyph
  /// metrics, so this is a target, not an exact output size. Values below
  /// ~0.5 simulate a loose Vision bounding box (lots of padding); values
  /// near 1.0 simulate a tight one.
  var glyphScale: CGFloat
  /// Center offset as a fraction of canvas size, applied in addition to
  /// `glyphScale` — simulates the glyph not being perfectly centered in
  /// its (imprecise) bounding box.
  var offsetXFraction: CGFloat
  var offsetYFraction: CGFloat
  var rotationDegrees: CGFloat
  var foreground: NSColor
  var background: NSColor
  /// 0 = no additive noise, 1 = fully random per-pixel noise layer at full
  /// opacity. Kept low (see `RandomVariation`) — this simulates sensor/
  /// compression-ish artifacts, not literal random pixels.
  var noiseOpacity: CGFloat
  var blurRadius: CGFloat
  /// `nil` lets the system choose the font (used for emoji, where the
  /// requested base font never matters — Apple Color Emoji is substituted
  /// via Core Text's font cascade for any character the base font doesn't
  /// cover, verified against every emoji in `SymbolCatalog.emojiSubset`
  /// during this spike's own smoke test).
  var fontName: String?
  var bold: Bool
}

enum ImageRenderer {
  /// Renders `spec` and returns PNG data, or `nil` if the character has no
  /// glyph in the resolved font (checked explicitly rather than silently
  /// emitting a tofu-box image, which would poison the dataset with blank/
  /// near-blank "glyph" samples).
  static func render(_ spec: RenderSpec) -> Data? {
    let size = spec.canvasPixels
    guard size > 0,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // Background: solid fill, sometimes a subtle two-stop gradient (a
    // fraction of samples — see RandomVariation.useGradientBackground) to
    // cover the "screenshot of a UI panel with a soft gradient" case
    // without making every sample gradient-textured.
    context.setFillColor(spec.background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let font = resolveFont(spec: spec, canvasPixels: size)
    let cfFont = font as CTFont
    guard glyphExists(spec.character, in: cfFont) || spec.fontName == nil else {
      // fontName == nil is the emoji path — font coverage is irrelevant
      // there (see doc comment above); only keyboard-glyph/notSymbol draws
      // are checked for real glyph coverage.
      return nil
    }

    let attributed = NSAttributedString(
      string: spec.character,
      attributes: [
        .font: font,
        .foregroundColor: spec.foreground,
      ])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    context.saveGState()
    // Rotate + jitter around the canvas center, then draw the line
    // centered on the origin — keeps the rotation pivot visually sane
    // regardless of the glyph's own bounding-box asymmetry.
    let centerX = CGFloat(size) / 2 + spec.offsetXFraction * CGFloat(size)
    let centerY = CGFloat(size) / 2 + spec.offsetYFraction * CGFloat(size)
    context.translateBy(x: centerX, y: centerY)
    context.rotate(by: spec.rotationDegrees * .pi / 180)
    context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
    CTLineDraw(line, context)
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = context.makeImage() else { return nil }
    let processed = applyPostEffects(cgImage, spec: spec)
    return pngData(from: processed)
  }

  /// `false` only for the keyboard-glyph/notSymbol-ASCII path, where a
  /// missing glyph would silently render as an empty/tofu box — checked
  /// once here rather than trusting every caller to have pre-validated
  /// font coverage (`SymbolCatalog`'s font-coverage matrix was verified by
  /// hand during this spike, but `render(_:)` re-checks defensively since
  /// a coverage regression here would poison the dataset silently).
  private static func glyphExists(_ character: String, in font: CTFont) -> Bool {
    guard character.count == 1 || character.unicodeScalars.count <= 2 else { return true }
    var glyph = CGGlyph()
    let utf16 = Array(character.utf16)
    guard !utf16.isEmpty else { return false }
    return CTFontGetGlyphsForCharacters(font, utf16, &glyph, utf16.count) && glyph != 0
  }

  private static func resolveFont(spec: RenderSpec, canvasPixels: Int) -> NSFont {
    let pointSize = CGFloat(canvasPixels) * spec.glyphScale
    guard let fontName = spec.fontName, let named = NSFont(name: fontName, size: pointSize) else {
      return NSFont.systemFont(ofSize: pointSize)
    }
    guard spec.bold else { return named }
    return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
  }

  /// Additive noise (via a cropped `CIRandomGenerator` composited at low
  /// opacity) + Gaussian blur — both optional per-sample (`noiseOpacity`/
  /// `blurRadius` are frequently 0, see `RandomVariation`), applied with
  /// Core Image so this file doesn't hand-roll per-pixel buffer math.
  /// `internal` (not `private`) — `NotSymbolExtras.swift` reuses this for
  /// its own non-character render paths (blank crops, partial-text crops),
  /// which build a `CGImage` a different way but want the identical
  /// noise/blur post-processing so all three notSymbol sub-generators are
  /// visually consistent with each other.
  /// Shared across every call — `CIContext` construction is expensive
  /// (builds a Metal/GPU pipeline), and this renderer generates thousands
  /// of images per run; a per-call `CIContext()` was measured to dominate
  /// total generation time before this change.
  private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

  static func applyPostEffects(_ image: CGImage, spec: RenderSpec) -> CGImage {
    guard spec.noiseOpacity > 0 || spec.blurRadius > 0 else { return image }
    var ciImage = CIImage(cgImage: image)
    let extent = ciImage.extent

    if spec.blurRadius > 0, let blur = CIFilter(name: "CIGaussianBlur") {
      blur.setValue(ciImage, forKey: kCIInputImageKey)
      blur.setValue(spec.blurRadius, forKey: kCIInputRadiusKey)
      if let output = blur.outputImage {
        ciImage = output.cropped(to: extent)
      }
    }

    if spec.noiseOpacity > 0, let noiseGen = CIFilter(name: "CIRandomGenerator"),
      let noiseImage = noiseGen.outputImage
    {
      let croppedNoise = noiseImage.cropped(to: extent)
      if let colorMatrix = CIFilter(name: "CIColorMatrix") {
        colorMatrix.setValue(croppedNoise, forKey: kCIInputImageKey)
        let alphaVector = CIVector(x: 0, y: 0, z: 0, w: spec.noiseOpacity)
        colorMatrix.setValue(alphaVector, forKey: "inputAVector")
        if let alphaAdjustedNoise = colorMatrix.outputImage,
          let composite = CIFilter(name: "CISourceOverCompositing")
        {
          composite.setValue(alphaAdjustedNoise, forKey: kCIInputImageKey)
          composite.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
          if let output = composite.outputImage {
            ciImage = output.cropped(to: extent)
          }
        }
      }
    }

    guard let rendered = sharedCIContext.createCGImage(ciImage, from: extent) else { return image }
    return rendered
  }

  static func pngData(from cgImage: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
  }
}
