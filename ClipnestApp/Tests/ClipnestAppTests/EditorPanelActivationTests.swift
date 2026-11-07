// EditorPanelActivationTests.swift
//
// T-EDIT19/T-EDIT20 regressions. Root causes (live focus traces, 2026-11-07):
// the item editor activated Clipnest (`NSApp.activate()`), so a paste after it
// closed failed `targetNoLongerFrontmost`; the snippet editor flipped the
// activation policy to `.regular` and back, and the deactivation that the flip
// back caused stripped the re-keyed picker of key status. Both editors are now
// non-activating `EditorPanel`s; these tests pin the properties that make that
// true. (Whether the window server actually keeps the user's app frontmost is
// verified live — see the T-EDIT19 report.)

import AppKit
import ClipnestCore
import ClipnestViewModels
import SwiftUI
import Testing

@testable import Clipnest

@MainActor
@Suite("Editor panels never activate Clipnest")
struct EditorPanelActivationTests {
  private static func editors() -> [EditorPanel] {
    [SnippetEditorWindow(), ItemEditorWindow()]
  }

  @Test("both editors are titled, closable, non-activating, key-capable panels")
  func editorsAreNonActivatingKeyCapablePanels() {
    for editor in Self.editors() {
      #expect(editor.styleMask.contains(.nonactivatingPanel))
      #expect(editor.styleMask.contains(.titled))
      #expect(editor.styleMask.contains(.closable))
      #expect(editor.canBecomeKey)
      // A panel hides on app deactivation by default; Clipnest is never the
      // active app while an editor is up, so that would hide it at once.
      #expect(editor.hidesOnDeactivate == false)
      #expect(editor.becomesKeyOnlyIfNeeded == false)
      #expect(editor.isReleasedWhenClosed == false)
    }
  }

  @Test("the item editor shows clipboard content, so it is excluded from screen sharing")
  func itemEditorSharingTypeIsNone() {
    #expect(ItemEditorWindow().sharingType == .none)
  }

  /// Red on the pre-fix code: `SnippetEditorWindow.show` flipped the policy to
  /// `.regular` (via `SettingsActivator`), and only flipped back once the
  /// window's close notification ran.
  @Test("showing and closing the snippet editor leaves the activation policy alone")
  func snippetEditorDoesNotTouchActivationPolicy() {
    let before = NSApp.activationPolicy()
    let window = SnippetEditorWindow()
    window.show(
      mode: .create, pickerPanel: nil, tagError: { _ in nil }, expandShortcut: "⌥⌘E",
      onSave: { _, _, _ in }, onClose: {})
    #expect(NSApp.activationPolicy() == before)
    window.close()
    #expect(NSApp.activationPolicy() == before)
  }

  @Test("onClose fires exactly once per present, for any close path")
  func onCloseFiresOncePerPresent() {
    let panel = EditorPanel()
    var closes = 0
    panel.present(content: NSView(), pickerPanel: nil, onClose: { closes += 1 })
    #expect(panel.isVisible)
    panel.close()
    panel.close()
    #expect(closes == 1)
    // Reused across presents: a fresh present re-arms the callback.
    panel.present(content: NSView(), pickerPanel: nil, onClose: { closes += 1 })
    panel.performClose(nil)
    #expect(closes == 2)
  }
}
