// ExpandSnippetHotkeyFloorBinding.swift
//
// T-HOTKEY1: re-installs the tier-4 GSettings custom-keybinding floor
// (`GSettingsCustomKeybinding`, this directory) with a freshly-rebound
// expand-snippet accelerator — the sibling of `ToggleHotkeyFloorBinding`
// for the SECOND global hotkey.
//
// Before this task, `LinuxAppLifecycle.installGSettingsFloor()` registered
// ONLY the toggle-picker floor binding. `SnippetExpander`'s expansion
// machinery was fully working end to end (verified via `clipnest-ctl
// expand-snippet` / `clipnest --expand-snippet`), and the Shell-extension
// path already dispatches it (`LinuxAppLifecycle`'s `onShortcutActivated`
// handling of `ShellExtensionKeybindingSchema.expandSnippetKey`) — but with
// no GNOME Shell extension installed (the common case), the ONLY way to
// reach it was that CLI command, which defeats the point of a global
// hotkey. This binding closes that gap the same way the toggle floor
// already does: a named GSettings custom keybinding under
// `org.gnome.settings-daemon.plugins.media-keys`, invoking this app's own
// `--expand-snippet` flag, independent of whether the Shell extension is
// installed — see `LinuxAppLifecycle.resolveAndApplyHotkeyBackend`'s doc
// comment on why the floor is installed UNCONDITIONALLY regardless of
// which tier is actually selected for delivery; that reasoning applies
// identically to this second binding.
//
// Default accelerator (`<Super><Shift>e`, set at the one call site in
// `LinuxAppLifecycle.installGSettingsFloor()`): pairs with the toggle
// floor's own `<Super><Shift>v` default the same way macOS pairs
// `⌥⌘V`/`⌥⌘E`. Verified free, not assumed, against a real GNOME Shell
// 42.9 session (`packaging/linux/gnome-shell-test/`): enumerated every key
// in `org.gnome.desktop.wm.keybindings`, `org.gnome.shell.keybindings`, and
// `org.gnome.settings-daemon.plugins.media-keys` — none of the three bind
// `<Super><Shift>e` (or `<Super><Shift>v`, confirming the existing toggle
// default was already safe) — then installed a real custom keybinding at
// this exact accelerator and confirmed via `xdotool key
// --clearmodifiers super+shift+e` that it fires through
// `gsd-media-keys` with no collision, independently of the toggle
// binding's own `<Super><Shift>v` firing correctly alongside it.
//
// `segment`/`bindingLabel` MUST stay in sync with wherever this type is
// called from, same drift risk `ToggleHotkeyFloorBinding`'s doc comment
// describes for its own segment. `LinuxAppLifecycle.installGSettingsFloor()`
// calls `reinstallFloor(withAccelerator:)` directly (as does this type's
// toggle sibling) rather than keeping a second, separately-literal copy of
// `segment`/`bindingLabel` — closing the exact drift risk
// `ToggleHotkeyFloorBinding.swift`'s own top doc comment flagged as a
// "recommended follow-up" for both bindings, not just this new one.
public enum ExpandSnippetHotkeyFloorBinding {
  public static let segment = "clipnest-expand-snippet"
  public static let bindingLabel = "Clipnest — Expand Snippet"

  /// Mirrors `ToggleHotkeyFloorBinding.reinstallFloor(withAccelerator:)`
  /// exactly, for the expand-snippet key instead of toggle-picker. Safe to
  /// call unconditionally on every successful rebind (`SettingsWindow
  /// +Shortcuts.swift`'s `GlobalHotkeyRecorder.commit(_:)`) AND at every
  /// startup (`LinuxAppLifecycle.installGSettingsFloor()`), regardless of
  /// which hotkey tier is currently resolved — same reasoning as the
  /// toggle sibling's own doc comment.
  public static func reinstallFloor(withAccelerator accelerator: String) {
    GSettingsCustomKeybinding.install(
      name: bindingLabel,
      command: "\(OwnExecutablePath.resolve()) \(LinuxAppCLIFlag.expandSnippet)",
      binding: accelerator, segment: segment)
  }
}
