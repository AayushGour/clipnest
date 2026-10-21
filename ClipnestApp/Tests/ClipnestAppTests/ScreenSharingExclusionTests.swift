// ScreenSharingExclusionTests.swift
//
// T-SHAREEXCL1: windows that show clipboard contents must opt out of screen
// sharing. The module name of the `ClipnestApp` target is `Clipnest`.

import AppKit
import SwiftUI
import Testing

@testable import Clipnest

@MainActor
@Suite("Screen sharing exclusion")
struct ScreenSharingExclusionTests {
  @Test("PickerPanel is excluded from screen sharing")
  func pickerPanelSharingTypeIsNone() {
    let panel = PickerPanel { Text("x") }
    #expect(panel.sharingType == .none)
  }

  @Test("SnippetEditorWindow (can be prefilled from a clipboard item) is excluded")
  func snippetEditorSharingTypeIsNone() {
    #expect(SnippetEditorWindow().sharingType == .none)
  }

  @Test("the item preview panel is excluded")
  func previewPanelSharingTypeIsNone() {
    #expect(ItemPreviewController().makePanel().sharingType == .none)
  }

  @Test("the snippet feedback HUD is excluded and never becomes key")
  func feedbackHUDIsExcludedAndNonActivating() {
    let panel = SnippetFeedbackHUD.makePanel()
    #expect(panel.sharingType == .none)
    #expect(panel.canBecomeKey == false)
    #expect(panel.ignoresMouseEvents)
  }

  @Test("excludeFromScreenSharing sets sharingType to none")
  func helperSetsNone() {
    let window = NSPanel(
      contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.sharingType = .readOnly
    window.excludeFromScreenSharing()
    #expect(window.sharingType == .none)
  }
}
