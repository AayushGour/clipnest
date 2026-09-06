// GTKGlobalHotkeyAcceleratorTests.swift
//
// T-OPT2 (Linux port, GTK4 view layer). Exercises
// `GlobalHotkeyAccelerator` (`Sources/ClipnestGTK/Hotkeys/
// GlobalHotkeyAccelerator.swift`) — the parts that are safe to assert in
// CI. Real GSettings writes/reads against the shared
// `app.clipnest.Clipnest.Keybindings` schema are "manual-verify only," the
// same documented category `GSettingsCustomKeybinding.install` (Clipnest
// LinuxAppKit) already falls into — there is no `dconf`/GSettings daemon
// in this test container. What IS both true and deterministic in every
// such container (no `.deb` ever installed, so the schema is never
// compiled into `/usr/share/glib-2.0/schemas`) is that the schema is
// ABSENT — this suite pins that defensive path directly, rather than
// leaving it completely untested.
import Testing

@testable import ClipnestGTK

@Suite("GlobalHotkeyAccelerator")
struct GTKGlobalHotkeyAcceleratorTests {
  @Test("write(_:) rejects an empty accelerator without touching GSettings at all")
  func writeRejectsEmptyString() {
    #expect(GlobalHotkeyAccelerator.write("") == false)
  }

  @Test(
    "In a dev/test container with no .deb ever installed, the shared schema is absent, so current()/write(_:) fail safe rather than aborting the process"
  )
  func failsSafeWhenSchemaNotInstalled() {
    // D68 (project-context.md): `g_settings_new` ABORTS the process on a
    // missing schema rather than returning nil — if `schemaIsInstalled()`'s
    // guard were missing or wrong, this test would crash the whole suite,
    // not merely fail an assertion.
    #expect(GlobalHotkeyAccelerator.current() == nil)
    #expect(GlobalHotkeyAccelerator.write("<Super><Shift>v") == false)
  }
}
