// ClipboardSelectionReplacer.swift
//
// The universal, works-in-any-app `SelectionReplacing` implementation used by
// `SnippetExpander`'s fallback path (when Accessibility can't read the
// selection — Electron/Chrome/Java apps). It drives synthesized Copy/Paste
// keystrokes (which every app supports) and snapshots + RESTORES the clipboard
// around the whole thing, so the user's clipboard ends up unchanged. Clipnest's
// own capture is suppressed for the duration via injected `beginSuppression`/
// `endSuppression` (wired to `ClipboardMonitor.pause()`/`ignore`+`resume` in
// `AppEnvironment`) so the transient copy/paste doesn't land in history.
//
// Posting `CGEvent` keystrokes requires Accessibility (same grant `Paster`
// already needs); without it the synthetic ⌘C is dropped, the pasteboard
// doesn't change, and this returns `.noSelection` (the expander then beeps).

import AppKit
import ClipnestCore
import CoreGraphics
import Foundation

@MainActor
final class ClipboardSelectionReplacer: SelectionReplacing {
  private let pasteboard: NSPasteboard

  /// Called before the clipboard is borrowed (→ `ClipboardMonitor.pause()`),
  /// and after it's restored (→ ignore the restore's change + `resume()`), so
  /// the transient copy/paste is never captured into history. Default no-ops.
  var beginSuppression: () -> Void = {}
  var endSuppression: () -> Void = {}

  /// Carbon virtual keycodes (`kVK_ANSI_C` / `kVK_ANSI_V`).
  private static let cKey: CGKeyCode = 0x08
  private static let vKey: CGKeyCode = 0x09

  /// Let the user's ⌥⌘E modifiers clear before posting ⌘C, so the synthetic
  /// keystroke isn't merged with a still-held ⌥/⌘.
  private static let modifierClearDelay = Duration.milliseconds(60)
  /// Poll step / ceiling while waiting for the frontmost app to write the
  /// copied selection to the pasteboard after ⌘C.
  private static let copyWaitStep = Duration.milliseconds(15)
  private static let copyMaxWait = Duration.milliseconds(500)
  /// Give the synthesized ⌘V time to land in the target app before the
  /// clipboard is restored out from under it.
  private static let pasteSettle = Duration.milliseconds(120)

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func replaceSelection(bodyForSelection: (String) async -> String?) async
    -> SelectionReplaceResult
  {
    beginSuppression()
    let snapshot = snapshotClipboard()
    defer {
      restoreClipboard(snapshot)
      endSuppression()
    }

    try? await Task.sleep(for: Self.modifierClearDelay)

    let before = pasteboard.changeCount
    guard postCommandKey(Self.cKey), await waitForChange(after: before) else {
      // ⌘C produced no clipboard change → nothing selected (or Accessibility
      // not granted, so the keystroke was dropped).
      return .noSelection
    }

    let selection = pasteboard.string(forType: .string) ?? ""
    guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .noSelection
    }
    guard let body = await bodyForSelection(selection) else {
      return .noMatch
    }

    pasteboard.clearContents()
    pasteboard.setString(body, forType: .string)
    guard postCommandKey(Self.vKey) else {
      return .noMatch
    }
    try? await Task.sleep(for: Self.pasteSettle)
    return .replaced
  }

  /// Waits (polling) up to `copyMaxWait` for the pasteboard's change count to
  /// move past `before`. Returns whether it changed.
  private func waitForChange(after before: Int) async -> Bool {
    var waited = Duration.zero
    while waited < Self.copyMaxWait {
      if pasteboard.changeCount != before { return true }
      try? await Task.sleep(for: Self.copyWaitStep)
      waited += Self.copyWaitStep
    }
    return pasteboard.changeCount != before
  }

  /// Posts a ⌘-modified keystroke through the global HID event tap (targeting
  /// whatever app is frontmost — the app the user is working in). Returns
  /// `false` only if the events couldn't be created.
  private func postCommandKey(_ key: CGKeyCode) -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  /// Copies the current pasteboard's items + all their type data so they can
  /// be written back verbatim by `restoreClipboard`.
  private func snapshotClipboard() -> [NSPasteboardItem] {
    (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          copy.setData(data, forType: type)
        }
      }
      return copy
    }
  }

  private func restoreClipboard(_ items: [NSPasteboardItem]) {
    pasteboard.clearContents()
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }
}
