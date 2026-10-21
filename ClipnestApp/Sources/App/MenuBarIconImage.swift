// MenuBarIconImage.swift
//
// T-PAUSEICON1: the menu-bar glyph for each capture state. A paused app drops
// copies silently, so the icon itself has to say so. The paused variant is the
// shipped `MenuBarIcon` artwork (derived from the master) drawn dimmed, plus a
// small pause mark — no card shape is redrawn. Always a TEMPLATE image, so
// AppKit tints it for light/dark menu bars.

import AppKit

enum MenuBarIconImage {
  static let assetName = "MenuBarIcon"
  /// Alpha the base glyph is drawn at while paused.
  static let pausedGlyphAlpha: CGFloat = 0.4

  static func image(isPaused: Bool) -> NSImage {
    let base = NSImage(named: assetName) ?? NSImage()
    guard isPaused, base.size.width > 0 else {
      base.isTemplate = true
      return base
    }
    let size = base.size
    let image = NSImage(size: size, flipped: false) { rect in
      base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: pausedGlyphAlpha)
      let barWidth = rect.width * 0.14
      let barHeight = rect.height * 0.46
      let gap = rect.width * 0.09
      let originX = rect.maxX - 2 * barWidth - gap - rect.width * 0.04
      NSColor.black.setFill()
      for index in 0..<2 {
        let bar = NSRect(
          x: originX + CGFloat(index) * (barWidth + gap), y: rect.minY + rect.height * 0.04,
          width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth * 0.3, yRadius: barWidth * 0.3).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
