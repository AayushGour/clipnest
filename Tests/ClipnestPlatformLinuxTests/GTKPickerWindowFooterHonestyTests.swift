// GTKPickerWindowFooterHonestyTests.swift
//
// Routed bug report ("pasting does nothing... the app gives the user no
// indication why") — Phase 2, "make it honest": exercises
// `PickerWindow.footerText(for:capabilities:isAutoPasteAvailable:)`, the
// pure decision behind `PickerWindow+Reconcile.swift`'s footer-text
// reconcile step. Confirmed live (see this task's report) that `Enter`
// still writes the pasteboard on `.clipboardOnly` — it just never
// synthesizes the keystroke `ShortcutHints`'s shared `"Enter paste"`
// wording (`ShortcutHints.swift`, out of this file's scope, shared with
// macOS) implies. This suite pins that `footerText` corrects exactly that
// one substring when `isAutoPasteAvailable` is `false`, leaves it alone
// when `true` (the working uinput/XTEST case must see byte-identical
// output to `ShortcutHints.text` — no regression for the common case), and
// never touches the Alt+Enter hints (which don't literally say "paste") or
// any other footer segment.
//
// See `GTKKeyEventMappingTests.swift`'s top doc comment for this module's
// shared `ClipnestPlatformLinuxTests` -> `ClipnestGTK` manifest-dependency
// note.
import Testing

@testable import ClipnestGTK
@testable import ClipnestViewModels

@Suite("PickerWindow.footerText")
struct GTKPickerWindowFooterHonestyTests {
  @Test("auto-paste available: byte-identical to ShortcutHints.text — no regression")
  func autoPasteAvailableIsUnchanged() {
    let capabilities = HighlightedItemCapabilities(item: nil)
    let shared = ShortcutHints.text(for: .history, capabilities: capabilities)
    let footer = PickerWindow.footerText(
      for: .history, capabilities: capabilities, isAutoPasteAvailable: true)
    #expect(footer == shared)
    #expect(footer.contains("Enter paste"))
  }

  @Test("clipboardOnly: \"Enter paste\" becomes \"Enter copy\" — Enter really does still copy")
  func clipboardOnlyCorrectsEnterWording() {
    let capabilities = HighlightedItemCapabilities(item: nil)
    let footer = PickerWindow.footerText(
      for: .history, capabilities: capabilities, isAutoPasteAvailable: false)
    #expect(footer.contains("Enter copy"))
    #expect(!footer.contains("Enter paste"))
  }

  @Test("clipboardOnly: every other footer segment is untouched")
  func clipboardOnlyLeavesRestOfFooterAlone() {
    let capabilities = HighlightedItemCapabilities(item: nil)
    let shared = ShortcutHints.text(for: .history, capabilities: capabilities)
    let footer = PickerWindow.footerText(
      for: .history, capabilities: capabilities, isAutoPasteAvailable: false)
    #expect(footer == shared.replacingOccurrences(of: "Enter paste", with: "Enter copy"))
  }

  @Test("clipboardOnly: holds across every tab, matching whatever ShortcutHints itself produces")
  func clipboardOnlyHoldsAcrossEveryTab() {
    let capabilities = HighlightedItemCapabilities(item: nil)
    for tab in PickerTab.allCases {
      let shared = ShortcutHints.text(for: tab, capabilities: capabilities)
      let footer = PickerWindow.footerText(
        for: tab, capabilities: capabilities, isAutoPasteAvailable: false)
      #expect(footer == shared.replacingOccurrences(of: "Enter paste", with: "Enter copy"))
    }
  }
}
