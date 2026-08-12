// SelectedTextAccessing.swift
//
// Reads and replaces the currently-selected text in the frontmost app via
// the Accessibility API (AX) — WITHOUT touching the pasteboard. Used by the
// snippet-expansion hotkey (see `SnippetExpander`). The `SelectedTextAccessing`
// protocol itself lives in `ClipnestCore` (so `SnippetExpander`'s decision
// logic is unit-testable with a mock, mirroring `Paster`'s
// protocol-in-Core/concrete-impl-in-app split); this file holds only the
// real AX-backed implementation, which is manual-verify only.
//
// `@preconcurrency import ApplicationServices`: the AX C API predates Swift
// concurrency auditing (same reason `PermissionsManager` needs it — see
// project-context.md D13), so importing it plainly can trip strict-
// concurrency diagnostics on its global constants.

@preconcurrency import ApplicationServices
import ClipnestCore

/// Production `SelectedTextAccessing` backed by the system-wide AX element.
struct AXSelectedTextAccessor: SelectedTextAccessing {
  func readSelectedText() -> String? {
    guard let focused = focusedElement() else { return nil }
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, &value)
    guard result == .success, let string = value as? String else { return nil }
    return string
  }

  @discardableResult
  func replaceSelectedText(with text: String) -> Bool {
    guard let focused = focusedElement() else { return false }
    let result = AXUIElementSetAttributeValue(
      focused, kAXSelectedTextAttribute as CFString, text as CFString)
    return result == .success
  }

  /// The system-wide focused UI element, or `nil` if none / AX unavailable.
  private func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
    guard result == .success else { return nil }
    // `focused` is an AXUIElement (a CFType); bridge it back. Unwrap before
    // calling `CFGetTypeID` — it dereferences its argument and does not
    // null-check, so a `.success` result with a nil out-value would crash
    // (EXC_BAD_ACCESS) if passed straight through.
    guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    return focused as! AXUIElement
  }
}
