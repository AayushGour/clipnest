// AppExpandSnippetHotkeyFloorBindingTests.swift
//
// T-HOTKEY1. Mirrors `AppToggleHotkeyFloorBindingTests.swift` exactly for
// `ExpandSnippetHotkeyFloorBinding` — `reinstallFloor(withAccelerator:)`
// itself does real GSettings I/O and is "manual-verify only" for the same
// reason `GSettingsCustomKeybinding.install` already is (no `dconf`/
// GSettings daemon in this test container). What IS deterministic and
// worth pinning: `segment`'s literal value and that it builds a valid
// (non-`customN`) GSettings path distinct from the toggle binding's own.
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ExpandSnippetHotkeyFloorBinding")
struct AppExpandSnippetHotkeyFloorBindingTests {
  @Test("segment is the stable literal LinuxAppLifecycle installs its floor binding under")
  func segmentIsStable() {
    #expect(ExpandSnippetHotkeyFloorBinding.segment == "clipnest-expand-snippet")
  }

  @Test("segment builds a valid (non-reserved) GSettings keybinding path")
  func segmentBuildsAValidPath() throws {
    let path = try GSettingsKeybindingPath.path(
      forSegment: ExpandSnippetHotkeyFloorBinding.segment)
    #expect(
      path
        == "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/clipnest-expand-snippet/"
    )
  }

  @Test("segment is distinct from the toggle-picker binding's segment")
  func segmentDiffersFromToggle() {
    // The whole point of a NAMED (not `customN`) segment is that two
    // distinct bindings never collide at the same GSettings path — see
    // `GSettingsKeybindingPath`'s top doc comment. A regression here would
    // mean one binding silently overwrites the other's name/command/
    // binding keys instead of both coexisting.
    #expect(ExpandSnippetHotkeyFloorBinding.segment != ToggleHotkeyFloorBinding.segment)
  }

  @Test("bindingLabel is non-empty (shown verbatim in GNOME Settings' own Keyboard panel)")
  func bindingLabelIsNonEmpty() {
    #expect(!ExpandSnippetHotkeyFloorBinding.bindingLabel.isEmpty)
  }

  @Test("bindingLabel is distinct from the toggle-picker binding's label")
  func bindingLabelDiffersFromToggle() {
    #expect(ExpandSnippetHotkeyFloorBinding.bindingLabel != ToggleHotkeyFloorBinding.bindingLabel)
  }
}
