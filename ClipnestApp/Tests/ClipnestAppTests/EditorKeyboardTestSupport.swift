// EditorKeyboardTestSupport.swift
//
// Shared by the item editor's and the snippet editor's keyboard tests
// (T-EDIT14 / T-EDIT15): synthetic key events and a reader for the live
// key-view loop of a real SwiftUI popup hosted in an off-screen window.

import AppKit
import SwiftUI

@MainActor
enum EditorKeyboardTestSupport {
  static func keyEvent(_ code: UInt16, chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
      keyCode: code)!
  }

  /// Accessibility identifiers of the key-view loop of `rootView`, in loop
  /// order, starting wherever the loop begins (it is a ring: use `rotated`).
  static func liveLoop<V: View>(
    _ rootView: V, size: NSSize = NSSize(width: 380, height: 460),
    textFieldIdentifiers: [String: String] = [:]
  ) -> [String] {
    let host = NSHostingView(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.autorecalculatesKeyViewLoop = true
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()
    var order: [String] = []
    var current = window.initialFirstResponder ?? host.nextValidKeyView
    var guardCount = 0
    var first: NSView?
    while let view = current, guardCount < 20 {
      if first == nil { first = view } else if view === first { break }
      let id = view.accessibilityIdentifier()
      if !id.isEmpty { order.append(id) }
      else if let field = view as? NSTextField, let placeholder = field.placeholderString,
        let mapped = textFieldIdentifiers[placeholder]
      {
        // SwiftUI applies a TextField's accessibility identifier to its AX
        // element, not to the backing NSTextField; recognise it by placeholder.
        order.append(mapped)
      }
      current = view.nextValidKeyView
      guardCount += 1
    }
    return order
  }

  /// `loop` rotated so it begins at `first` (loops are rings).
  static func rotated(_ loop: [String], toStartAt first: String) -> [String] {
    let start = loop.firstIndex(of: first) ?? 0
    return Array(loop[start...] + loop[..<start])
  }
}
