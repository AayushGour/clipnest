// SnippetFeedbackHUDTests.swift
//
// T-SNIPFB1: HUD placement stays on screen; with no screen it falls back to the
// beep. (Showing a real panel is not exercised: no window-server side effects.)

import AppKit
import Testing

@testable import Clipnest

@MainActor
@Suite("SnippetFeedbackHUD")
struct SnippetFeedbackHUDTests {
  private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
  private let size = NSSize(width: 300, height: 80)

  @Test("Placed below-right of the pointer when there is room")
  func belowRight() {
    let origin = SnippetFeedbackHUD.frameOrigin(
      pointer: NSPoint(x: 400, y: 400), size: size, screenVisibleFrame: screen)
    #expect(origin.x == 400 + SnippetFeedbackHUD.pointerOffset)
    #expect(origin.y == 400 - SnippetFeedbackHUD.pointerOffset - size.height)
  }

  @Test("Clamped inside the screen at the right edge, flipped above at the bottom")
  func clampsAndFlips() {
    let origin = SnippetFeedbackHUD.frameOrigin(
      pointer: NSPoint(x: 990, y: 10), size: size, screenVisibleFrame: screen)
    #expect(origin.x == screen.maxX - size.width)
    #expect(origin.y == 10 + SnippetFeedbackHUD.pointerOffset)
    #expect(NSContainsRect(screen, NSRect(origin: origin, size: size)))
  }
}
