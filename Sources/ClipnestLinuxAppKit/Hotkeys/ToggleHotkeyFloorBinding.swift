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
// `segment`/`bindingLabel` below MUST match `LinuxAppLifecycle`'s own
// (currently `private`, file-scoped) `toggleKeybindingSegment`/`"Clipnest —
// Toggle Picker"` literal exactly — both ultimately call
// `GSettingsCustomKeybinding.install`, keyed by `segment`
// (`GSettingsKeybindingPath.path(forSegment:)`), for the SAME logical
// binding. A mismatch would silently create a second, orphaned custom
// keybinding at a different GSettings path instead of updating the one the
// app installed at first launch, rather than erroring. Recommended
// follow-up (reported to the task's coordinator, not applied here —
// `LinuxAppLifecycle.swift` is outside this task's owned-files scope):
// change that `private` constant to reference `ToggleHotkeyFloorBinding
// .segment`/`.bindingLabel` instead of keeping its own copy, so the two can
// never drift apart. `AppToggleHotkeyFloorBindingTests.swift` pins today's
// literal value (`"clipnest-toggle"`) against `GSettingsKeybindingPath` as
// a regression guard until that consolidation happens.
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
