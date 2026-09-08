// AppToggleHotkeyFloorBindingTests.swift
//
// T-OPT2. `ToggleHotkeyFloorBinding.reinstallFloor(withAccelerator:)`
// itself does real GSettings I/O (via `GSettingsCustomKeybinding.install`)
// and is "manual-verify only" for the same reason that type's own `install`
// already is (no `dconf`/GSettings daemon in this test container — see
// `GSettingsCustomKeybinding.swift`'s doc comment). What IS a real
// regression risk worth pinning here: `segment`'s own literal value —
// `LinuxAppLifecycle.installGSettingsFloor()` now calls this type's
// `reinstallFloor(withAccelerator:)` directly instead of keeping a second,
// separate copy of the literal (T-HOTKEY1 consolidation — see
// `ToggleHotkeyFloorBinding.swift`'s top doc comment), which removed the
// drift risk this suite originally existed to catch; it still pins
// `segment`'s value as a regression guard on this type's own identity.
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ToggleHotkeyFloorBinding")
struct AppToggleHotkeyFloorBindingTests {
  @Test("segment is the stable literal LinuxAppLifecycle installs its floor binding under")
  func segmentMatchesLinuxAppLifecyclesLiteral() {
    // T-HOTKEY1: `LinuxAppLifecycle.installGSettingsFloor()` now calls
    // `ToggleHotkeyFloorBinding.reinstallFloor(withAccelerator:)` directly
    // rather than keeping its own separate, `private` copy of this literal
    // — so there is only one place this value can change. Still pinned
    // here as a plain regression guard on the value itself (a rename would
    // silently orphan the GSettings entry every prior install already
    // created under the old segment).
    #expect(ToggleHotkeyFloorBinding.segment == "clipnest-toggle")
  }

  @Test("segment builds a valid (non-reserved) GSettings keybinding path")
  func segmentBuildsAValidPath() throws {
    let path = try GSettingsKeybindingPath.path(forSegment: ToggleHotkeyFloorBinding.segment)
    #expect(
      path
        == "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/clipnest-toggle/")
  }

  @Test("bindingLabel is non-empty (shown verbatim in GNOME Settings' own Keyboard panel)")
  func bindingLabelIsNonEmpty() {
    #expect(!ToggleHotkeyFloorBinding.bindingLabel.isEmpty)
  }
}
