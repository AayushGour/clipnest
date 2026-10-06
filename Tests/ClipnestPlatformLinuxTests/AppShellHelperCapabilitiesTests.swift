import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ShellHelperCapabilities negotiation")
struct AppShellHelperCapabilitiesTests {
  @Test("nameHasOwner false always yields .unavailable, regardless of the raw capabilities list")
  func noOwnerIsUnavailable() {
    let result = ShellHelperCapabilities.negotiate(
      nameHasOwner: false, rawCapabilities: ["clipboard", "hotkeys"])
    #expect(result == .unavailable)
    #expect(!result.isPresent)
  }

  @Test("recognized capability strings are parsed into the typed set")
  func recognizedCapabilitiesParse() {
    let result = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["clipboard", "hotkeys", "paste"])
    #expect(result.isPresent)
    #expect(result.capabilities == [.clipboard, .hotkeys, .paste])
  }

  @Test("unrecognized capability strings are dropped, not treated as a parse failure")
  func unrecognizedCapabilitiesAreDropped() {
    let result = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["clipboard", "some-future-feature"])
    #expect(result.isPresent)
    #expect(result.capabilities == [.clipboard])
  }

  @Test("canSynthesizeKeystrokes requires both presence and the paste capability")
  func canSynthesizeKeystrokesRequiresPaste() {
    let withPaste = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["paste"])
    let withoutPaste = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["clipboard"])
    #expect(withPaste.canSynthesizeKeystrokes)
    #expect(!withoutPaste.canSynthesizeKeystrokes)
    #expect(!ShellHelperCapabilities.unavailable.canSynthesizeKeystrokes)
  }

  @Test("canResolvePointerAndFocus requires BOTH pointer and focus")
  func canResolvePointerAndFocusRequiresBoth() {
    let both = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["pointer", "focus"])
    let pointerOnly = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["pointer"])
    #expect(both.canResolvePointerAndFocus)
    #expect(!pointerOnly.canResolvePointerAndFocus)
  }

  @Test("canDeliverShortcuts and canPlaceWindows map to hotkeys/placement respectively")
  func hotkeysAndPlacementMapCorrectly() {
    let hotkeys = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["hotkeys"])
    let placement = ShellHelperCapabilities.negotiate(
      nameHasOwner: true, rawCapabilities: ["placement"])
    #expect(hotkeys.canDeliverShortcuts)
    #expect(!hotkeys.canPlaceWindows)
    #expect(placement.canPlaceWindows)
    #expect(!placement.canDeliverShortcuts)
  }
}
