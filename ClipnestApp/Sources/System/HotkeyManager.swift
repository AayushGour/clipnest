// HotkeyManager.swift
//
// Plan task T27: the global hotkey that opens Clipnest's picker from
// anywhere, without needing the menu bar.
//
// ⌥⌘V pass-through, and why there are TWO delivery mechanisms
// -----------------------------------------------------------
// `.togglePicker` was originally delivered by `KeyboardShortcuts.onKeyDown`,
// i.e. a Carbon `RegisterEventHotKey` hotkey. A Carbon hotkey CONSUMES the
// keystroke exclusively: while Clipnest ran, macOS's own ⌥⌘V ("Move Item
// Here" — paste a cut file in Finder) never fired, because Clipnest swallowed
// the chord before Finder's menu system saw it.
//
// The fix is to match the chord from `NSEvent` monitors instead, which cannot
// consume a keystroke destined for another app — so the picker opens AND
// Finder still gets ⌥⌘V. That is the same mechanism the app the user compared
// this to uses (its binary imports `addGlobalMonitorForEventsMatchingMask:`,
// not `RegisterEventHotKey`).
//
// The catch, and the reason `deliveryMode` exists: an `NSEvent` GLOBAL key
// monitor only receives events while the process is Accessibility-trusted.
// Shipping monitors unconditionally meant that on a fresh install — before
// the user has granted anything — the shortcut was simply dead, with no
// feedback. That is a strictly worse first-run experience than the Carbon
// hotkey it replaced, which needed no permission at all.
//
// So the mechanism is chosen from the live trust state, and re-chosen
// whenever it changes (`AccessibilityPermissionWatcher` drives
// `applyDeliveryMode()` from `AppEnvironment`):
//
//   NOT trusted -> Carbon hotkey. Works immediately, no permission. Consumes
//                  ⌥⌘V, so Finder does not get it — the pre-existing
//                  behavior, and strictly better than a dead shortcut.
//   trusted     -> NSEvent monitors. Non-consuming, so Finder gets ⌥⌘V too.
//
// Exactly one mechanism is live at a time; switching tears the other down
// (`KeyboardShortcuts.removeHandler(for:)` also unregisters the underlying
// Carbon hotkey, so the chord is genuinely released).
//
// The LOCAL monitor is part of the trusted mode only, and unlike the global
// one it DOES consume on a match (returns `nil`) — passing the chord through
// to our own picker would type `√` (Option-V) into its search field.
//
// `.expandSnippet` is deliberately never moved off Carbon — it replaces the
// user's selected text, so letting the same chord also reach the target app
// is wrong.
//
// Privacy: the global monitor is handed every key-down system-wide, but this
// file only ever reads `keyCode`/`modifierFlags` for an equality check
// against the configured shortcut. Nothing is stored, logged, or forwarded —
// `event.characters` is never touched, and the debug logging below records
// only which mechanism is live, never a keystroke.

import AppKit
import ClipnestCore
import KeyboardShortcuts
import os

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
  /// Which mechanism is currently delivering `.togglePicker`. See this
  /// file's header for why it depends on Accessibility trust.
  enum DeliveryMode: String {
    /// `KeyboardShortcuts`' Carbon `RegisterEventHotKey`. No permission
    /// required; consumes the chord.
    case carbonHotkey
    /// `NSEvent` global + local monitors. Requires Accessibility; the global
    /// one cannot consume, so other apps still receive the chord.
    case eventMonitors
  }

  private static let logger = Logger(
    subsystem: ClipnestLog.subsystem, category: "HotkeyManager")

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

  /// The mechanism currently live, or `nil` before `register(onToggle:)`.
  /// Readable so the Permissions/Shortcuts UI and the logs can say which one
  /// is in effect rather than guessing.
  private(set) static var deliveryMode: DeliveryMode?

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

  /// The mechanism that should be live for a given Accessibility trust
  /// state. Split out as a pure function so the decision itself is testable
  /// without touching the real permission or installing anything.
  static func deliveryMode(forAccessibilityGranted isGranted: Bool) -> DeliveryMode {
    isGranted ? .eventMonitors : .carbonHotkey
  }

  /// Registers `.togglePicker` to call `onToggle`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching` (via `AppEnvironment`).
  static func register(onToggle: @escaping () -> Void) {
    toggleAction = onToggle
    refreshShortcut()
    observeLibraryNotifications()
    applyDeliveryMode()
  }

  /// Registers `.expandSnippet` to call `onExpand`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching` (via `AppEnvironment`).
  /// Always the library's consuming Carbon registration — see the header.
  static func registerExpandSnippet(onExpand: @escaping () -> Void) {
    KeyboardShortcuts.onKeyDown(for: .expandSnippet, action: onExpand)
  }

  /// Re-picks the delivery mechanism from the current Accessibility trust
  /// state and installs it, tearing down whatever was live before.
  ///
  /// `AppEnvironment` wires this to `AccessibilityPermissionWatcher`'s
  /// change callback, so the shortcut keeps working across a grant OR a
  /// revocation with no relaunch. It must be a full teardown/reinstall
  /// rather than a no-op when the mode is unchanged: a global key monitor
  /// installed while untrusted stays dead for its whole lifetime, macOS does
  /// not retroactively start delivering to it once the grant lands.
  ///
  /// No-op before `register(onToggle:)` has run.
  static func applyDeliveryMode() {
    guard toggleAction != nil else { return }

    removeMonitors()
    KeyboardShortcuts.removeHandler(for: .togglePicker)

    let mode = deliveryMode(forAccessibilityGranted: PermissionsManager.isGranted)
    switch mode {
    case .eventMonitors:
      installMonitors()
    case .carbonHotkey:
      KeyboardShortcuts.onKeyDown(for: .togglePicker) {
        logger.debug("togglePicker fired from the Carbon hotkey")
        toggleAction?()
      }
    }
    deliveryMode = mode

    // `.notice`, not `.debug`: debug-level entries are not persisted to the
    // unified log, so `log show` cannot retrieve them after the fact — and
    // "which mechanism did it actually choose on that machine" is precisely
    // the question worth being able to answer from a user's Mac without
    // asking them to reproduce under `log stream`. Fires once per mode
    // change, carries no keystroke data.
    logger.notice(
      """
      togglePicker delivery=\(mode.rawValue, privacy: .public) \
      shortcut=\(toggleShortcut?.description ?? "none", privacy: .public) \
      globalMonitorInstalled=\(globalMonitor != nil, privacy: .public)
      """)
  }

  private static func installMonitors() {
    // Global: fires only while ANOTHER app is frontmost, and has no return
    // value — it cannot consume, which is the entire point (Finder still
    // receives ⌥⌘V). Returns nil, and never fires, without Accessibility —
    // which is exactly why this mode is only selected when trusted.
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
    logger.debug("togglePicker fired from the global monitor")
    toggleAction?()
  }

  private static func handleLocal(_ event: NSEvent) -> NSEvent? {
    // A capturing Recorder owns the keyboard — recording ⌥⌘V must record,
    // not open the picker.
    guard !isRecorderActive else { return event }
    guard shouldToggle(for: event, matching: toggleShortcut) else { return event }
    logger.debug("togglePicker fired from the local monitor")
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
        MainActor.assumeIsolated {
          refreshShortcut()
          // The Carbon path re-registers itself inside the library, but the
          // monitor path reads `toggleShortcut` — both are covered by simply
          // reapplying the current mode.
          applyDeliveryMode()
        }
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
