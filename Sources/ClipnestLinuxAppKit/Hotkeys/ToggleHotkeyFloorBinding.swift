// ToggleHotkeyFloorBinding.swift
//
// T-OPT2: re-installs the tier-4 GSettings custom-keybinding floor
// (`GSettingsCustomKeybinding`, this directory) with a freshly-rebound
// toggle-picker accelerator, so a rebind made from Settings > Shortcuts
// takes effect even for users running with no GNOME Shell extension (the
// floor, not the shared `app.clipnest.Clipnest.Keybindings` schema, is what
// actually delivers the hotkey in that case). Called from
// `ClipnestGTK.SettingsWindow`'s injected `reinstallToggleHotkeyFloor`
// closure — see that type's doc comment for why a closure crosses this
// module boundary rather than a direct call (`ClipnestGTK` cannot import
// `ClipnestLinuxAppKit`; `Package.swift`'s dependency edge runs the other
// way).
//
// `segment`/`bindingLabel` below are the single source of truth for this
// binding's identity — `GSettingsCustomKeybinding.install`, keyed by
// `segment` (`GSettingsKeybindingPath.path(forSegment:)`), is how both
// `LinuxAppLifecycle.installGSettingsFloor()` (startup) and this file's own
// `reinstallFloor(withAccelerator:)` (a Settings > Shortcuts rebind) locate
// the SAME logical GSettings entry. A mismatch between the two call sites
// would silently create a second, orphaned custom keybinding at a
// different GSettings path instead of updating the one installed at first
// launch, rather than erroring.
//
// **T-HOTKEY1 consolidation:** `LinuxAppLifecycle` previously kept its own
// separate, `private`, file-scoped copy of this exact literal
// (`toggleKeybindingSegment = "clipnest-toggle"`) rather than referencing
// this type — flagged here as a "recommended follow-up" but not applied,
// since that file was outside the task that found it. Now fixed:
// `installGSettingsFloor()` calls `ToggleHotkeyFloorBinding
// .reinstallFloor(withAccelerator:)` directly (the same function this
// file's own rebind call site uses), so there is exactly one copy of
// `segment`/`bindingLabel` for this binding, not two that could drift.
// `AppToggleHotkeyFloorBindingTests.swift` still pins the literal value
// (`"clipnest-toggle"`) against `GSettingsKeybindingPath` as a regression
// guard on this type's own identity.
public enum ToggleHotkeyFloorBinding {
  public static let segment = "clipnest-toggle"
  public static let bindingLabel = "Clipnest — Toggle Picker"

  /// Re-runs `GSettingsCustomKeybinding.install` (unchanged — this is not a
  /// new persistence path, just a new call site) with `accelerator` as the
  /// binding. Safe to call unconditionally on every successful rebind,
  /// regardless of which hotkey tier is currently active
  /// (`HotkeyBackendResolver`) — if the Shell extension is live, Mutter's
  /// own single-grab-per-accelerator semantics mean this floor simply never
  /// wins the grab; if the extension is absent or later disabled, the floor
  /// already carries the correct, current accelerator rather than a stale
  /// one from first launch.
  public static func reinstallFloor(withAccelerator accelerator: String) {
    GSettingsCustomKeybinding.install(
      name: bindingLabel,
      command: "\(OwnExecutablePath.resolve()) \(LinuxAppCLIFlag.togglePicker)",
      binding: accelerator, segment: segment)
  }
}
