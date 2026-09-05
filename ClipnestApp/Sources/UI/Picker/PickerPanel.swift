// PickerPanel.swift
//
// Plan task T10: the picker's window chrome only — no picker *content* here
// (that's `PickerView`, T11). Content-agnostic by design: the generic
// `init<Content: View>` accepts any SwiftUI view, so this file has zero
// dependency on `ClipnestCore` or picker state.

import AppKit
import ClipnestViewModels
import SwiftUI

/// Non-activating floating panel that hosts Clipnest's picker UI.
///
/// Configured borderless + `.nonactivatingPanel` so it can become key (to
/// accept keyboard input in the search field, see `PickerView`) WITHOUT
/// activating Clipnest itself: AppKit lets a panel with `.nonactivatingPanel`
/// in its style mask become the key window without bringing its owning app
/// to the foreground. That means `NSWorkspace.frontmostApplication` keeps
/// reporting whatever app the user was in before opening the picker — the
/// same technique Spotlight-style launcher panels (Alfred, Raycast, etc.)
/// use, and the reason a later synthesized paste (plan tasks T14–T16) can
/// still target the right app instead of Clipnest itself.
///
/// `show(at:)` therefore deliberately never calls `NSApp.activate` or
/// `makeKeyAndOrderFront` — both would activate the app. It calls
/// `orderFrontRegardless()` + `makeKey()` instead.
@MainActor
public final class PickerPanel: NSPanel {
  /// The panel's fixed content size. Declared once here so `PickerView`
  /// doesn't need to duplicate the same width/height literals to fill it —
  /// see `PickerView`'s `.frame(maxWidth: .infinity, maxHeight: .infinity)`.
  private static let defaultSize = NSSize(width: 560, height: 420)

  /// The physical Delete/Backspace key's virtual keycode (`kVK_Delete`) —
  /// NOT `kVK_ForwardDelete`/117. Used by the local event monitor installed
  /// in `configure()` to recognize ⌘⌫ ahead of the search field's field
  /// editor; see `onCommandDelete`'s doc comment.
  private static let deleteKeyCode: UInt16 = 51

  /// The physical `,` key's virtual keycode (`kVK_ANSI_Comma`). Used by the
  /// same local event monitor to recognize ⌘, ahead of `NSApp.mainMenu`'s
  /// own key-equivalent matching; see `onCommandComma`'s doc comment.
  private static let commaKeyCode: UInt16 = 43

  /// Invoked right before the panel is ordered to the front, on *every*
  /// `show(at:)` call — not just the first. Lets the composition root reset
  /// picker state (search query, live-refresh polling, search-field focus)
  /// without `PickerPanel` itself knowing anything about picker content.
  public var onWillShow: (() -> Void)?

  /// Invoked right after the panel is ordered out (from `hide()`).
  public var onDidHide: (() -> Void)?

  /// Invoked when ⌘⌫ (Command+Delete) is pressed while this panel is key.
  /// `PickerPanel` intercepts this itself, via a local `NSEvent` monitor,
  /// rather than leaving it to SwiftUI's `.onKeyPress` in `PickerView`:
  /// the picker's search field is an always-focused `NSTextField` (SwiftUI
  /// `TextField` + `.focused()`), and its field editor consumes Cmd+Delete
  /// as its own text-editing command ("delete to line start") before
  /// `.onKeyPress` ever sees the keystroke — same family of bug as the
  /// earlier Return-key issue (see `PickerView`'s doc comment), but this
  /// time there's no SwiftUI-level equivalent to `.onSubmit` to fix it at
  /// that layer, so it has to be intercepted here at the AppKit layer
  /// instead, before the field editor gets it.
  public var onCommandDelete: (() -> Void)?

  /// Invoked when ⌘, (Command+Comma) is pressed while this panel is key —
  /// T-SET5.
  ///
  /// A SECOND, independently-discovered reason (beyond `onCommandDelete`'s
  /// field-editor one) why a key has to be intercepted here at the AppKit
  /// layer instead of `PickerView`'s SwiftUI `.onKeyPress`: declaring a
  /// `Settings` scene makes SwiftUI auto-generate a "Settings…" command
  /// bound to ⌘, in the app's (possibly not currently visible) main menu,
  /// wired directly to its own `openSettings()`. `-[NSApplication
  /// sendEvent:]` matches a physical keyDown against `NSApp.mainMenu`'s key
  /// equivalents BEFORE the key window's responder chain (and therefore
  /// before SwiftUI's `.onKeyPress`) ever sees it — and this matching does
  /// NOT require Clipnest to be the active/frontmost app, only that one of
  /// its own windows (this panel) is currently `key`. Confirmed live
  /// (T-SET5 manual verification): with no interception, ⌘, while the
  /// picker is open silently creates the Settings window via that built-in
  /// path but never raises or activates it — the exact T-SET1 failure mode
  /// `SettingsActivator` exists to fix — so a `PickerView`-level
  /// `.onKeyPress(",")` case would be unreachable dead code; a local
  /// `NSEvent` monitor is the only layer that runs early enough to preempt
  /// the built-in handler and substitute Clipnest's own (dismiss the
  /// picker, then the same `openSettings()` + `SettingsFocusCoordinator`
  /// sequence `MenuBarContent`'s "Settings…" item uses).
  public var onCommandComma: (() -> Void)?

  /// Token for the local `NSEvent` monitor installed in `configure()` that
  /// implements `onCommandDelete`/`onCommandComma`. Removed in `deinit`. The
  /// token's type (`Any?`, opaque per `NSEvent.addLocalMonitorForEvents`'s
  /// signature) isn't `Sendable`, which the nonisolated `deinit` below needs
  /// to read it to remove the monitor — `nonisolated(unsafe)` is safe here
  /// (see `BlobStore.fileManager`'s doc comment for the same pattern)
  /// because this property is only ever written once, synchronously, from
  /// `configure()` during `@MainActor`-isolated `init`, and only ever read
  /// in `deinit`, which by construction can't run concurrently with that
  /// write (an object can't be deallocated while its own init is still
  /// running) or with itself (deinit runs exactly once).
  private nonisolated(unsafe) var localKeyMonitor: Any?

  /// Creates a panel hosting `content` via `NSHostingView`.
  public convenience init<Content: View>(@ViewBuilder content: () -> Content) {
    self.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize))
    let hostingView = NSHostingView(rootView: content())
    hostingView.frame = NSRect(origin: .zero, size: Self.defaultSize)
    hostingView.autoresizingMask = [.width, .height]
    contentView = hostingView
  }

  private init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configure()
  }

  /// Never used (no Interface Builder/NSCoding archiving anywhere in
  /// Clipnest) — required by `NSWindow`'s `NSCoding` conformance whenever a
  /// subclass adds its own designated initializer.
  @available(*, unavailable, message: "PickerPanel does not support NSCoding")
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for PickerPanel")
  }

  /// `PickerPanel` is `@MainActor`; `deinit` is nonisolated by default in
  /// Swift 6, and `NSEvent.removeMonitor` isn't actor-isolated, so this
  /// compiles as a plain (implicitly nonisolated) `deinit` — no explicit
  /// `nonisolated` needed, given `localKeyMonitor`'s own
  /// `nonisolated(unsafe)` above already makes it accessible here.
  deinit {
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
    }
  }

  private func configure() {
    isFloatingPanel = true
    // `.floating` alone sits too low to appear over another app's
    // full-screen content (fix round 1, bug #3 — confirmed by runtime
    // testing) — `.popUpMenu` is the level Apple documents for transient,
    // always-on-top UI like this, and combined with `collectionBehavior`
    // below is what actually gets the panel drawn on top of a full-screen
    // app's Space.
    level = .popUpMenu
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    isMovableByWindowBackground = true
    isOpaque = true
    backgroundColor = .windowBackgroundColor
    hasShadow = true
    // `.canJoinAllSpaces` makes the panel present on every Space at once
    // (including whichever one is active when `show()` is called, with no
    // Space-switch animation), and `.fullScreenAuxiliary` is specifically
    // what allows it to draw on top of another app's full-screen content
    // in that Space — both are required together for the full-screen AC.
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    // Intercepts ⌘⌫ ahead of the search field's field editor (see
    // `onCommandDelete`'s doc comment) and ⌘, ahead of
    // `NSApp.mainMenu`'s auto-generated Settings key equivalent (see
    // `onCommandComma`'s doc comment) — two independent reasons for the
    // same mechanism, checked in one monitor rather than installing two.
    // Returning `nil` from a local monitor's handler swallows the event:
    // per `NSEvent.addLocalMonitorForEvents`'s documented semantics, a
    // `nil` return means the event is never dispatched further — to the
    // window/first responder for ⌘⌫ (stopping the field editor's own
    // "delete to line start" AND `PickerView`'s `.onKeyPress(.delete)` case
    // from also firing for the same keystroke, avoiding a double-delete),
    // or to `-[NSApplication sendEvent:]`'s menu key-equivalent matching
    // for ⌘, (stopping the built-in, silently-non-raising `openSettings()`
    // call from firing instead of/in addition to Clipnest's own). Any other
    // key, or either of these keys without Command, returns `event`
    // unchanged so normal text editing in the search field (and everything
    // else) is completely unaffected.
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, event.window === self else { return event }
      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
      else { return event }
      switch event.keyCode {
      case Self.deleteKeyCode:
        self.onCommandDelete?()
        return nil
      case Self.commaKeyCode:
        self.onCommandComma?()
        return nil
      default:
        return event
      }
    }
  }

  /// A borderless panel defaults `canBecomeKey`/`canBecomeMain` to `false`;
  /// overriding both is required so the panel — and the search field inside
  /// it — can actually receive keyboard input once shown.
  override public var canBecomeKey: Bool { true }
  override public var canBecomeMain: Bool { false }

  /// Shows the panel at `point` (screen coordinates, AppKit's bottom-left
  /// origin), or — when `point` is `nil` — at the mouse cursor's current
  /// location, on whichever screen the cursor is actually on (not a fixed
  /// screen), clamped so the panel never renders off that screen's visible
  /// area. Never activates Clipnest; see the type's doc comment.
  public func show(at point: CGPoint? = nil) {
    position(at: point ?? NSEvent.mouseLocation)
    onWillShow?()
    orderFrontRegardless()
    makeKey()
  }

  /// Hides the panel. Safe to call even if already hidden.
  public func hide() {
    guard isVisible else { return }
    orderOut(nil)
    onDidHide?()
  }

  private func position(at point: CGPoint) {
    guard let screen = screenContaining(point) else { return }
    let visible = screen.visibleFrame
    // Anchor the panel's top-left near the cursor, so it "drops down" from
    // the cursor like a context menu, rather than the cursor landing in its
    // middle.
    let origin = NSPoint(x: point.x, y: point.y - frame.height)
    setFrameOrigin(clampedOrigin(origin, in: visible))
  }

  /// The screen actually containing `point` — i.e. the screen the mouse
  /// cursor is currently on — falling back to the main screen only if that
  /// somehow can't be determined (e.g. `point` sits exactly on a screen
  /// boundary in a multi-monitor setup).
  private func screenContaining(_ point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
  }

  private func clampedOrigin(_ origin: NSPoint, in bounds: NSRect) -> NSPoint {
    // Delegates to the shared helper — see `WindowPlacement`'s doc comment
    // for why this formula lives in exactly one place. Fully qualified
    // (P5, Phase 3 Linux port): this SDK's `SwiftUI` also declares a public
    // `WindowPlacement` struct, so the bare name is ambiguous once both
    // `ClipnestViewModels` and `SwiftUI` are imported.
    ClipnestViewModels.WindowPlacement.clampedOrigin(origin, size: frame.size, in: bounds)
  }
}
