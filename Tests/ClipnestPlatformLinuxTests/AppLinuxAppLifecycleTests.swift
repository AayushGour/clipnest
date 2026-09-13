// AppLinuxAppLifecycleTests.swift
//
// T-WLKEY-CLOBBER: `LinuxAppLifecycle.installGSettingsFloor()` itself does
// real GSettings I/O (`GlobalHotkeyAccelerator.current(_:)`,
// `ToggleHotkeyFloorBinding`/`ExpandSnippetHotkeyFloorBinding
// .reinstallFloor(withAccelerator:)`) and is "manual-verify only" for the
// same reason every other GSettings-touching type in this module already
// is (no `dconf`/GSettings daemon in this test container). What IS a real
// regression risk worth pinning here — and the whole bug this task
// fixes — is `resolvedAccelerator(storedValue:defaultValue:)`'s decision:
// a user's stored accelerator must always win over the hardcoded default,
// never the other way around. Extracted as a small pure function
// (`LinuxAppLifecycle.swift`'s doc comment) specifically so this is
// testable without touching real GSettings.
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("LinuxAppLifecycle.resolvedAccelerator")
struct AppLinuxAppLifecycleTests {
  @Test("a stored accelerator wins over the default — the bug this task fixes")
  func storedValueWinsOverDefault() {
    // Before the fix, `installGSettingsFloor()` passed the hardcoded
    // default straight through on every launch, silently overwriting
    // whatever a user had rebound from Settings > Shortcuts and persisted
    // to the shared `app.clipnest.Clipnest.Keybindings` schema.
    #expect(
      LinuxAppLifecycle.resolvedAccelerator(
        storedValue: "<Shift><Control>v", defaultValue: "<Super><Shift>v")
        == "<Shift><Control>v")
  }

  @Test("falls back to the default only when nothing is stored")
  func fallsBackToDefaultWhenUnset() {
    #expect(
      LinuxAppLifecycle.resolvedAccelerator(storedValue: nil, defaultValue: "<Super><Shift>v")
        == "<Super><Shift>v")
  }

  @Test("an empty stored string is still treated as a real stored value, not defaulted")
  func emptyStoredStringIsNotTreatedAsUnset() {
    // `GlobalHotkeyAccelerator.current(_:)` itself never returns an empty
    // string (it returns `nil` for an unbound/missing key) — this pins
    // `resolvedAccelerator`'s own contract precisely (only `nil` falls
    // back), independent of that caller's behavior.
    #expect(
      LinuxAppLifecycle.resolvedAccelerator(storedValue: "", defaultValue: "<Super><Shift>v")
        == "")
  }
}
