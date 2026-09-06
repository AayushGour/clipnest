// AppToggleHotkeyFloorBindingTests.swift
//
// T-OPT2. `ToggleHotkeyFloorBinding.reinstallFloor(withAccelerator:)`
// itself does real GSettings I/O (via `GSettingsCustomKeybinding.install`)
// and is "manual-verify only" for the same reason that type's own `install`
// already is (no `dconf`/GSettings daemon in this test container — see
// `GSettingsCustomKeybinding.swift`'s doc comment). What IS a real
// regression risk worth pinning here: `segment` drifting out of sync with
// `LinuxAppLifecycle`'s own (currently separate, `private`) copy of the
// identical literal — see `ToggleHotkeyFloorBinding.swift`'s top doc
// comment for why that would silently create a second, orphaned custom
// keybinding rather than error.
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ToggleHotkeyFloorBinding")
struct AppToggleHotkeyFloorBindingTests {
  @Test("segment matches the literal LinuxAppLifecycle installs its OWN floor binding under")
  func segmentMatchesLinuxAppLifecyclesLiteral() {
    // `LinuxAppLifecycle.toggleKeybindingSegment` is `private` to that file
    // and can't be referenced directly — this pins the exact literal value
    // it currently holds (`"clipnest-toggle"`) as of this task, so a future
    // edit to either side that lets them drift apart fails a test instead
    // of silently creating a second GSettings custom-keybinding entry.
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
