// HotkeyManager.swift
//
// Plan task T27: the global hotkey that opens Clipnest's picker from
// anywhere, without needing the menu bar. Built on `KeyboardShortcuts`
// (Sindre Sorhus, MIT — see coding-standards.md's Dependency policy; the
// one approved third-party dependency, `ClipnestApp`-only) rather than a
// hand-rolled Carbon/`CGEventTap` global hotkey implementation, per that
// policy.

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  /// Toggles Clipnest's picker panel open. Default **⌥⌘V** (Option+Command+V)
  /// — a deliberate product decision overriding the original spec's ⌘⇧V
  /// default (see project-context.md D11) — applied automatically the first
  /// time this `Name` is referenced with nothing already saved in
  /// `UserDefaults` (that's `KeyboardShortcuts.Name.init`'s own documented
  /// behavior, not something `HotkeyManager` re-implements). Exposed here as
  /// a `Name`, not hidden as a private detail of `HotkeyManager`, so a
  /// future Settings recorder (`KeyboardShortcuts.Recorder`, plan task T28)
  /// can bind to it directly without any change to this file.
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
  /// Default **⌥⌘E**. Exposed as a `Name` so a future Settings recorder can
  /// bind to it directly.
  static let expandSnippet = Self(
    "expandSnippet",
    initial: .init(.e, modifiers: [.command, .option])
  )
}

/// Registers the global `.togglePicker` hotkey.
///
/// Deliberately thin: `KeyboardShortcuts` owns the actual low-level global
/// event tap, persistence of any user-customized shortcut, and the
/// first-launch-default behavior documented on
/// `KeyboardShortcuts.Name.togglePicker` above — there's no meaningful pure
/// logic left in this type to unit test. Registration itself (does pressing
/// ⌥⌘V from another app actually open the picker) is only verifiable by an
/// actual run — see the fix-round-2 report for the documented manual check,
/// not a faked automated test.
@MainActor
enum HotkeyManager {
  /// Registers `.togglePicker` to call `onToggle`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching` (via `AppEnvironment`).
  static func register(onToggle: @escaping () -> Void) {
    KeyboardShortcuts.onKeyDown(for: .togglePicker, action: onToggle)
  }

  /// Registers `.expandSnippet` to call `onExpand`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching` (via `AppEnvironment`).
  static func registerExpandSnippet(onExpand: @escaping () -> Void) {
    KeyboardShortcuts.onKeyDown(for: .expandSnippet, action: onExpand)
  }
}
