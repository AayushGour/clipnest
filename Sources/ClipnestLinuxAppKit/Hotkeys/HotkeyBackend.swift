import Foundation

/// Which mechanism delivers a global-hotkey activation to this app —
/// this task's priority chain, in priority order (highest first).
public enum HotkeyBackend: Equatable, Sendable {
  /// `app.clipnest.ShellHelper`'s mutter-level keybinding
  /// (`app.clipnest.Clipnest.Keybindings` GSettings schema +
  /// `ShortcutActivated` signal) — works on both X11 and Wayland sessions,
  /// and is the only tier that hands `ShowPicker` pointer/monitor/focus
  /// info in the same event with no extra round trip.
  ///
  /// Selecting this tier requires TWO independent facts, not one — see
  /// `HotkeyBackendResolver.resolve`'s doc comment: the audit that opened
  /// this task found a stub `ShellHelperService` whose `Capabilities`
  /// property genuinely advertised `"hotkeys"` (grabbing the mutter
  /// keybinding is a real, independent side effect of enabling that one
  /// capability) while the object exported NO methods at all — so every
  /// D-Bus call, including the one this tier depends on
  /// (`ShortcutActivated`'s delivery has no separate call, but the same
  /// broken method table means nothing else works either), silently failed
  /// with `UnknownMethod`. Trusting `Capabilities` alone in that state
  /// swallows the global hotkey with no fallback — installing the
  /// "recommended" extension made the app strictly worse than not
  /// installing it at all.
  case shellExtensionKeybinding
  /// `XGrabKey` — X11-only. **BLOCKED in this build**: see
  /// `HotkeyBackendResolver`'s doc comment — `ClipnestLinuxApp` has no
  /// declared dependency on `CXlib` (`Package.swift`, out of this task's
  /// scope to edit), so there is no Xlib call available to this module at
  /// all. The resolver still models this tier so the decision logic is
  /// correct the moment that dependency edge is added; production always
  /// passes `xGrabKeyAvailable: false` today.
  case xGrabKey
  /// `org.freedesktop.portal.GlobalShortcuts` — requires GNOME 47+; not
  /// present on this project's target releases (22.04/24.04), per the
  /// task brief. Detection-only in this build (see
  /// `GlobalShortcutsPortalClient`) — the full session/token bind
  /// handshake is unimplemented since this tier cannot fire on any
  /// supported release, and building an untestable, never-exercised
  /// multi-step D-Bus handshake would be speculative scope, not a real
  /// capability.
  case globalShortcutsPortal
  /// A GSettings custom keybinding invoking this app's own CLI (`clipnest
  /// --toggle-picker`, forwarded through `SingleInstance.forwardArguments`
  /// to the running instance) — the universal floor: works on every
  /// target release and both session types, with no extension and no
  /// portal required. See `GSettingsCustomKeybinding`.
  case gsettingsFloor
}

/// Pure priority decision — extracted from the actual capability probing
/// (a live D-Bus call to check the extension, an attempted `XGrabKey`, a
/// portal introspection call — all real, unverifiable-in-CI I/O) so the
/// DECISION LOGIC itself is unit-testable independent of what's actually
/// reachable on this machine. Mirrors
/// `ClipnestPlatformLinux.LinuxEventSynthesizerSelection.choose`'s exact
/// shape and reasoning for the paste-backend priority chain.
///
/// `shellExtensionKeybindingAvailable` (the self-reported `Capabilities`
/// string) is deliberately never trusted alone. A caller must ALSO supply
/// `shellExtensionLiveDispatchConfirmed` — the result of a real D-Bus call
/// that got a real, correctly-shaped reply (see
/// `ShellHelperClient.probeLiveDispatch()`) — and both must be true before
/// this tier is selected. This is the fix for the capability trap this
/// task's audit found: a `ShellHelperService` that advertises `"hotkeys"`
/// but dispatches no method at all must fall through to a lower tier, not
/// silently claim the hotkey and then never fire it.
public enum HotkeyBackendResolver {
  public static func resolve(
    shellExtensionKeybindingAvailable: Bool,
    shellExtensionLiveDispatchConfirmed: Bool,
    xGrabKeyAvailable: Bool,
    globalShortcutsPortalAvailable: Bool
  ) -> HotkeyBackend {
    if shellExtensionKeybindingAvailable && shellExtensionLiveDispatchConfirmed {
      return .shellExtensionKeybinding
    }
    if xGrabKeyAvailable { return .xGrabKey }
    if globalShortcutsPortalAvailable { return .globalShortcutsPortal }
    return .gsettingsFloor
  }
}
