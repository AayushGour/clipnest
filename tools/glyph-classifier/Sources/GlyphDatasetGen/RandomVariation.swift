// RandomVariation.swift
//
// T-GLY1: samples the "how does this look" half of a `RenderSpec` (the
// "what character" half is the caller's job). Centralizing every random
// range here means the whole dataset's variety profile is auditable in one
// file instead of scattered `Double.random(in:)` calls through the
// generator's class loops.

import AppKit
import Foundation

enum RandomVariation {
  /// Fonts known (per this spike's hand-verified coverage matrix — see
  /// `font_check.swift`/`font_check2.swift` in the spike's scratch
  /// workspace, not committed) to contain every `SymbolCatalog
  /// .keyboardGlyphs` character. `nil` = let the system resolve the
  /// default UI font. Used for BOTH keyboard-glyph rendering and
  /// notSymbol's ASCII/confusable rendering, so the two classes share a
  /// font-variety profile — a real classifier must tell a Menlo "H" apart
  /// from a Menlo "⌘", not just a system-font one.
  static let glyphCapableFontNames: [String?] = [nil, "Menlo", "Menlo-Bold", "Lucida Grande"]

  /// Broader font pool for plain ASCII notSymbol content, where every
  /// system font has full Latin/digit/punctuation coverage — deliberately
  /// wider than `glyphCapableFontNames` so notSymbol sees more visual
  /// variety than the glyph classes do (asymmetric on purpose: notSymbol
  /// is the highest-value class to generalize well, per this spike's gate).
  static let asciiFontNames: [String?] = [
    nil, "Menlo", "Menlo-Bold", "Helvetica", "Helvetica Neue", "Lucida Grande", "Courier",
    "Andale Mono",
  ]

  static func canvasPixels(using generator: inout SystemRandomNumberGenerator) -> Int {
    Int.random(in: 28...132, using: &generator)
  }

  /// Loose-to-tight crop simulation — see `RenderSpec.glyphScale`'s doc
  /// comment. Skewed toward the tighter end (`0.55...0.95`) because that's
  /// the common case for a real Vision character bounding box, with a
  /// looser tail (`0.3...0.55`) sampled a third of the time to cover boxes
  /// Vision drew too generously.
  static func glyphScale(using generator: inout SystemRandomNumberGenerator) -> CGFloat {
    if Double.random(in: 0...1, using: &generator) < 0.33 {
      return CGFloat.random(in: 0.30...0.55, using: &generator)
    }
    return CGFloat.random(in: 0.55...0.95, using: &generator)
  }

  static func offsetFraction(using generator: inout SystemRandomNumberGenerator) -> CGFloat {
    CGFloat.random(in: -0.12...0.12, using: &generator)
  }

  static func rotationDegrees(using generator: inout SystemRandomNumberGenerator) -> CGFloat {
    CGFloat.random(in: -10...10, using: &generator)
  }

  static func noiseOpacity(using generator: inout SystemRandomNumberGenerator) -> CGFloat {
    Double.random(in: 0...1, using: &generator) < 0.4
      ? CGFloat.random(in: 0.02...0.12, using: &generator) : 0
  }

  static func blurRadius(using generator: inout SystemRandomNumberGenerator) -> CGFloat {
    Double.random(in: 0...1, using: &generator) < 0.3
      ? CGFloat.random(in: 0.2...1.0, using: &generator) : 0
  }

  /// A (foreground, background) pair spanning light mode, dark mode, and
  /// deliberately low-contrast combinations — the last group matters
  /// because a low-contrast real screenshot crop is exactly the case where
  /// a classifier is most likely to guess wrong, and it needs to see that
  /// case in training, not just clean high-contrast renders.
  static func colorPair(using generator: inout SystemRandomNumberGenerator) -> (
    foreground: NSColor, background: NSColor
  ) {
    let roll = Double.random(in: 0...1, using: &generator)
    switch roll {
    case ..<0.4:
      // Light mode: dark text on a near-white/light background.
      let bgGray = CGFloat.random(in: 0.85...1.0, using: &generator)
      let fgGray = CGFloat.random(in: 0.0...0.25, using: &generator)
      return (
        NSColor(white: fgGray, alpha: 1), NSColor(white: bgGray, alpha: 1)
      )
    case ..<0.75:
      // Dark mode: light text on a near-black/dark background — this
      // codebase's real menu bar/panel UI supports dark mode, and screen
      // shots of it are exactly what a user might copy/paste.
      let bgGray = CGFloat.random(in: 0.0...0.2, using: &generator)
      let fgGray = CGFloat.random(in: 0.8...1.0, using: &generator)
      return (
        NSColor(white: fgGray, alpha: 1), NSColor(white: bgGray, alpha: 1)
      )
    default:
      // Low-contrast: fg/bg grays close together, in either direction —
      // the hard case named explicitly in the task brief.
      let base = CGFloat.random(in: 0.3...0.7, using: &generator)
      let delta = CGFloat.random(in: 0.05...0.25, using: &generator)
      let lighter = min(1, base + delta)
      let darker = max(0, base - delta)
      return Bool.random(using: &generator)
        ? (NSColor(white: darker, alpha: 1), NSColor(white: lighter, alpha: 1))
        : (NSColor(white: lighter, alpha: 1), NSColor(white: darker, alpha: 1))
    }
  }

  static func bold(using generator: inout SystemRandomNumberGenerator) -> Bool {
    Bool.random(using: &generator)
  }
}
