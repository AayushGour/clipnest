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
//
// T-HOTKEY1: `current`/`write` are now `Key`-parameterized (toggle-picker
// AND expand-snippet share the same schema) — every case below is
// exercised for both keys so a future regression that only breaks one of
// them (e.g. a copy-paste that hardcodes `.togglePicker`'s key name) fails
// a test.
import Testing

@testable import ClipnestGTK

@Suite("GlobalHotkeyAccelerator")
struct GTKGlobalHotkeyAcceleratorTests {
  @Test(
    "write(_:for:) rejects an empty accelerator without touching GSettings at all",
    arguments: [GlobalHotkeyAccelerator.Key.togglePicker, .expandSnippet]
  )
  func writeRejectsEmptyString(key: GlobalHotkeyAccelerator.Key) {
    #expect(GlobalHotkeyAccelerator.write("", for: key) == false)
  }

  @Test(
    "In a dev/test container with no .deb ever installed, the shared schema is absent, so current(_:)/write(_:for:) fail safe rather than aborting the process",
    arguments: [GlobalHotkeyAccelerator.Key.togglePicker, .expandSnippet]
  )
  func failsSafeWhenSchemaNotInstalled(key: GlobalHotkeyAccelerator.Key) {
    // D68 (project-context.md): `g_settings_new` ABORTS the process on a
    // missing schema rather than returning nil — if `schemaIsInstalled()`'s
    // guard were missing or wrong, this test would crash the whole suite,
    // not merely fail an assertion.
    #expect(GlobalHotkeyAccelerator.current(key) == nil)
    #expect(GlobalHotkeyAccelerator.write("<Super><Shift>v", for: key) == false)
  }

  @Test("Key.settingsKeyName matches ShellExtensionKeybindingSchema's action names exactly")
  func settingsKeyNamesMatchTheSharedSchema() {
    // `ShellExtensionKeybindingSchema` (`ClipnestLinuxAppKit/DBus/
    // ShellHelperNames.swift`) is unreachable from this module (see this
    // file's top doc comment) — these two literals are pinned directly
    // against the schema XML's own key names instead
    // (`packaging/linux/schemas/app.clipnest.Clipnest.Keybindings.gschema.xml`),
    // so a typo here fails a test rather than silently producing a
    // GSettings key the extension/app never agree on.
    #expect(GlobalHotkeyAccelerator.Key.togglePicker.settingsKeyName == "toggle-picker")
    #expect(GlobalHotkeyAccelerator.Key.expandSnippet.settingsKeyName == "expand-snippet")
  }
}
