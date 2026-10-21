// MenuBarIconImageTests.swift — T-PAUSEICON1: both states stay template
// images, and the paused variant is a genuinely different bitmap.

import AppKit
import Testing

@testable import Clipnest

@Suite("MenuBarIconImage")
struct MenuBarIconImageTests {
  private func pngData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
      return nil
    }
    return rep.representation(using: .png, properties: [:])
  }

  @Test("both states are template images so they tint for light/dark menu bars")
  func bothStatesAreTemplates() {
    #expect(MenuBarIconImage.image(isPaused: false).isTemplate)
    #expect(MenuBarIconImage.image(isPaused: true).isTemplate)
  }

  @Test("the paused icon differs from the active icon and keeps its size")
  func pausedDiffersFromActive() {
    let active = MenuBarIconImage.image(isPaused: false)
    let paused = MenuBarIconImage.image(isPaused: true)
    #expect(active.size == paused.size)
    #expect(pngData(active) != nil)
    #expect(pngData(active) != pngData(paused))
  }
}
