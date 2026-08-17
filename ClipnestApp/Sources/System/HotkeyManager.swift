// HotkeyManager.swift
//
// Plan task T27: the global hotkey that opens Clipnest's picker from
// anywhere, without needing the menu bar.
//
// ⌥⌘V pass-through fix
// --------------------
// `.togglePicker` used to be registered through `KeyboardShortcuts.onKeyDown`,
// which registers a Carbon `RegisterEventHotKey` hotkey. A Carbon hotkey
// CONSUMES the keystroke exclusively: while Clipnest was running, macOS's own
// ⌥⌘V ("Move Item Here" — paste a cut file in Finder) never fired, because
// Clipnest swallowed the chord before Finder's menu system saw it.
//
// `.togglePicker` is therefore matched from `NSEvent` monitors instead:
//
//   * the GLOBAL monitor (`addGlobalMonitorForEvents`) sees keystrokes while
//     another app is frontmost and — by design, there is no return value —
//     CANNOT consume them. Clipnest opens its picker and Finder still gets
//     ⌥⌘V. That is exactly the mechanism the app the user compared this to
//     uses (its binary imports `addGlobalMonitorForEventsMatchingMask:`, not
//     `RegisterEventHotKey`).
//
//   * the LOCAL monitor (`addLocalMonitorForEvents`) covers the case where
//     Clipnest itself has key focus (picker panel open, Settings window
//     open). This one DOES consume on a match (returns `nil`) — passing the
//     chord through to our own picker would type `√` (Option-V) into the
//     search field.
//
// Cost of this mechanism, deliberately accepted: an `NSEvent` global key
// monitor only receives events when the process is Accessibility-trusted, so
// unlike the old Carbon hotkey, `.togglePicker` no longer works before the
// user grants Accessibility. `AccessibilityPermissionWatcher` +
// `reinstallMonitors()` handle the grant landing later (see below), and the
// Permissions settings tab tells the user when the hotkey is inert.
//
// `.expandSnippet` is deliberately NOT moved to this mechanism — it replaces
// the user's selected text, so letting the same chord also reach the target
// app is wrong. It keeps the consuming Carbon registration.
//
// Privacy: the global monitor is handed every key-down system-wide, but this
// file only ever reads `keyCode`/`modifierFlags` for an equality check
// against the configured shortcut. Nothing is stored, logged, or forwarded —
// `event.characters` is never touched.

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  /// Toggles Clipnest's picker panel open. Default **⌥⌘V** (Option+Command+V)
  /// — a deliberate product decision overriding the original spec's ⌘⇧V
  /// default (see project-context.md D11) — applied automatically the first
  /// time this `Name` is referenced with nothing already saved in
  /// `UserDefaults` (that's `KeyboardShortcuts.Name.init`'s own documented
  /// behavior, not something `HotkeyManager` re-implements).
  ///
  /// Sharing the chord with Finder's "Move Item Here" is fine as of the
  /// pass-through fix — see this file's header.
  ///
  /// `KeyboardShortcuts.Name`/`Shortcut` are `nonisolated`/`Sendable` as of
  /// the pinned 3.x line (they weren't in 1.x — verified directly against
  /// the pinned tag's source, see project-context.md D11), so this needs no
  /// actor-isolation workaround under Swift 6 strict concurrency. `initial:`
  /// (not the deprecated `default:` label) is the 3.x parameter name.
  static let togglePicker = Self(
    "togglePicker",
    initial: .init(.v, modifiers: [.command, .option])
  )

  /// Expands the selected text as a snippet keyword (see `SnippetExpander`).
  /// Default **⌥⌘E**. Exposed as a `Name` so the Settings recorder can bind
  /// to it directly.
  static let expandSnippet = Self(
    "expandSnippet",
    initial: .init(.e, modifiers: [.command, .option])
  )
}

/// Registers Clipnest's two global hotkeys — `.togglePicker` via
/// non-consuming `NSEvent` monitors, `.expandSnippet` via the
/// `KeyboardShortcuts` library's consuming Carbon registration. See this
/// file's header for why the two differ.
///
/// The library is still the source of truth for what the shortcuts ARE
/// (persistence, the `Recorder` UI, first-launch defaults); this type only
/// takes over *delivery* for `.togglePicker`. Because
/// `KeyboardShortcuts.onKeyDown` is never called for `.togglePicker`, the
/// library's `registerIfNeeded(for:)` short-circuits on its
/// `hasActiveHandlers(for:)` guard and no Carbon hotkey is ever registered
/// for that chord — which is what actually frees ⌥⌘V for Finder.
@MainActor
enum HotkeyManager {
  /// Posted by `KeyboardShortcuts` whenever a stored shortcut changes (the
  /// user recording a new one in Settings). The library declares this name
  /// internally, so it is matched here by its stable raw string.
  private static let shortcutDidChangeNotification = Notification.Name(
    "KeyboardShortcuts_shortcutByNameDidChange")

  /// Posted by `KeyboardShortcuts.Recorder` when it starts/stops capturing.
  /// While a recorder is capturing, the local monitor must stay out of the
  /// way or recording ⌥⌘-anything would also fire the picker.
  private static let recorderActiveNotification = Notification.Name(
    "KeyboardShortcuts_recorderActiveStatusDidChange")

  /// `userInfo` key carried by `recorderActiveNotification` — also internal
  /// to the library, matched by raw string for the same reason.
  private static let recorderIsActiveKey = "isActive"

  private static var toggleAction: (() -> Void)?
  private static var toggleShortcut: KeyboardShortcuts.Shortcut?
  private static var isRecorderActive = false
  private static var globalMonitor: Any?
  private static var localMonitor: Any?
  private static var observers: [NSObjectProtocol] = []

  /// Whether `event` should fire the picker toggle, given the currently
  /// configured `shortcut`. Pure and `static` so `HotkeyManagerTests` can
  /// exercise the matching rules against synthesized `NSEvent`s without
  /// installing a real monitor.
  ///
  /// Auto-repeat is excluded: holding the chord down must open the picker
  /// once, not once per repeat tick. Modifier normalization (ignoring Caps
  /// Lock, the numeric-pad flag, and Fn) is `KeyboardShortcuts.Shortcut`'s
  /// own `init?(event:)` behavior, reused here rather than reimplemented.
  static func shouldToggle(for event: NSEvent, matching shortcut: KeyboardShortcuts.Shortcut?)
    -> Bool
  {
    guard let shortcut, !event.isARepeat else { return false }
    return KeyboardShortcuts.Shortcut(event: event) == shortcut
  }

  /// Registers `.togglePicker` to call `onToggle`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching` (via `AppEnvironment`).
  static func register(onToggle: @escaping () -> Void) {
    toggleAction = onToggle
    refreshShortcut()
    observeLibraryNotifications()
    installMonitors()
  }

  /// Registers `.expandSnippet` to call `onExpand`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching` (via `AppEnvironment`).
  /// Still the library's consuming Carbon registration — see the header.
  static func registerExpandSnippet(onExpand: @escaping () -> Void) {
    KeyboardShortcuts.onKeyDown(for: .expandSnippet, action: onExpand)
  }

  /// Tears down and reinstalls the `NSEvent` monitors.
  ///
  /// Required because a global key monitor installed while the process is
  /// not Accessibility-trusted stays dead for the monitor's whole lifetime —
  /// macOS does not retroactively start delivering to it when the grant
  /// lands. `AppEnvironment` wires this to
  /// `AccessibilityPermissionWatcher.onGranted` so the hotkey starts working
  /// the moment the user flips the switch, with no relaunch.
  ///
  /// No-op before `register(onToggle:)` has run.
  static func reinstallMonitors() {
    guard toggleAction != nil else { return }
    removeMonitors()
    installMonitors()
  }

  private static func installMonitors() {
    // Global: fires only while ANOTHER app is frontmost, and has no return
    // value — it cannot consume, which is the entire point (Finder still
    // receives ⌥⌘V). Requires Accessibility; silently never fires without it.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
      handleGlobal(event)
    }

    // Local: fires while Clipnest holds key focus. Consumes on a match so
    // the chord never reaches the picker's search field as text.
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleLocal(event)
    }
  }

  private static func removeMonitors() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }

  private static func handleGlobal(_ event: NSEvent) {
    guard shouldToggle(for: event, matching: toggleShortcut) else { return }
    toggleAction?()
  }

  private static func handleLocal(_ event: NSEvent) -> NSEvent? {
    // A capturing Recorder owns the keyboard — recording ⌥⌘V must record,
    // not open the picker.
    guard !isRecorderActive else { return event }
    guard shouldToggle(for: event, matching: toggleShortcut) else { return event }
    toggleAction?()
    return nil
  }

  private static func refreshShortcut() {
    toggleShortcut = KeyboardShortcuts.getShortcut(for: .togglePicker)
  }

  private static func observeLibraryNotifications() {
    guard observers.isEmpty else { return }

    observers.append(
      NotificationCenter.default.addObserver(
        forName: shortcutDidChangeNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { refreshShortcut() }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: recorderActiveNotification, object: nil, queue: .main
      ) { notification in
        let active = notification.userInfo?[recorderIsActiveKey] as? Bool ?? false
        MainActor.assumeIsolated { isRecorderActive = active }
      })
  }
}
