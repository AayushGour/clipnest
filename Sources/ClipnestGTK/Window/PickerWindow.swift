// PickerWindow.swift
//
// P7-D (Linux port, GTK4 view layer): the GTK4 counterpart of macOS's
// `PickerPanel`/`PickerView` — a borderless picker window driven by the
// SHARED `PickerViewModel` (`ClipnestViewModels`), built directly on GTK4's
// C API through `CGtk4` (see `Interop/GTKCallbackTrampoline.swift` for the
// signal-callback pattern every extension file here reuses).
//
// ACTOR ISOLATION: `PickerViewModel` is `@MainActor`. This type is
// deliberately NOT annotated `@MainActor` itself, to keep its public API
// (`init`/`show`/`hide`/`windowToken`) exactly the plain, non-async shape
// this task's API contract specifies — annotating the type would force
// every caller (including `ClipnestLinuxApp`, built by a different agent
// against that exact contract) into an `await`/MainActor context this
// contract never asked for. Instead, every place this file (and its
// extensions) touches `viewModel` goes through `MainActor.assumeIsolated
// { ... }` — a synchronous assertion, not a hop. This is sound specifically
// because GTK's entire event model is single-threaded: `ClipnestGTKApplication
// .initializeGTK()`/`.runMainLoop()` run on the process's one and only GTK
// thread, every GTK signal this module connects to fires back in on that
// SAME thread (GLib's main loop never dispatches a signal callback from a
// worker thread), and nothing in this module ever spawns a `Task` that
// would migrate `PickerViewModel` work elsewhere — so "the thread GTK is
// running on" and "the thread Swift's default main-actor executor runs on"
// are the same thread for this whole subsystem's lifetime, which is
// exactly `assumeIsolated`'s documented precondition.
//
// WINDOW PLACEMENT: this type does NOT position, raise-above, or hide-from-
// taskbar its own window — GTK4 removed `gtk_window_move`/`gtk_window_set_
// keep_above`/skip-taskbar entirely from the portable `GtkWindow` API (verified
// against GTK4's migration docs; these became X11-only backend concepts with
// no Wayland equivalent). That is precisely why `windowToken` exists: per
// `extension/src/core/iface.js`'s `app.clipnest.ShellHelper1.PlaceWindow(
// window_token, x, y, flags)` D-Bus method and `extension/src/core/placement.js`
// (`Placement._findByToken`, matching purely on `win.get_title() == token`),
// the GNOME Shell extension finds this exact window by its title and moves/
// raises/stickies it directly through Mutter — a capability only the
// compositor has. `ClipnestLinuxApp` (a different agent's scope) is expected
// to call that D-Bus method with the SAME point passed to `show(at:)`,
// using `windowToken` — `show(at:)` accepts `point` to match this task's API
// contract exactly, but cannot itself act on it; see that method's doc
// comment.
//
// LIFETIME: `connectSignals()` passes `self` as several signals' retained
// trampoline context (see `Interop/GTKCallbackTrampoline.swift`), which
// means GTK holds a permanent strong reference to this instance for as
// long as its window/widgets exist. That is intentional, not a leak: a
// picker window is a long-lived, effectively singleton controller for the
// app's whole run (shown/hidden via `show`/`hide`, never rebuilt), matching
// `PickerPanel`'s lifetime on macOS — nothing in this task's scope ever
// calls `gtk_window_destroy` on it.
import CGtk4
import ClipnestCore
import ClipnestViewModels
import Foundation

// `@unchecked Sendable`: Swift 6's "sending" analysis (SE-0414) flags every
// `MainActor.assumeIsolated { viewModel.foo() }` call below and in this
// type's extensions with "sending 'self' risks causing data races," since
// `self` (a plain, non-actor class) is captured inside a `@MainActor`
// closure while ALSO being used elsewhere (every other such call, plus
// every GTK trampoline holding a retained reference — see this file's top
// "LIFETIME" doc comment). The compiler cannot prove this is safe from
// static analysis alone; this file's top "ACTOR ISOLATION" doc comment IS
// that proof, established independently of the type system: every access
// to `self`/`viewModel` happens on the single GTK thread, which is the
// same thread the whole process's main-actor work runs on, for this
// subsystem's entire lifetime — the same "single caller thread, not
// concurrent access" guarantee `BlobStore` already documents its own
// `nonisolated(unsafe)` with elsewhere in this codebase.
public final class PickerWindow: @unchecked Sendable {
  /// Matches `PickerPanel.defaultSize` (`NSSize(width: 560, height: 420)`,
  /// `ClipnestApp/Sources/UI/Picker/PickerPanel.swift`) — the picker keeps
  /// the same footprint on both platforms.
  static let defaultWidth: Int32 = 560
  static let defaultHeight: Int32 = 420

  let viewModel: PickerViewModel
  let onDismiss: () -> Void
  public let windowToken: String

  // MARK: - Widgets (built by `buildLayout()`, `PickerWindow+Layout.swift`)

  let window: OpaquePointer
  let searchEntry: OpaquePointer
  let tabsBox: OpaquePointer
  let chipsBox: OpaquePointer
  let scrolledWindow: OpaquePointer
  let listBox: OpaquePointer
  let loadingLabel: OpaquePointer
  let footerLabel: OpaquePointer
  let previewPopover: OpaquePointer
  let previewImage: OpaquePointer
  let previewLabel: OpaquePointer

  /// One `GtkToggleButton` per `PickerTab`, index-aligned with
  /// `PickerTab.allCases` — built/wired in `PickerWindow+Chips.swift`.
  var tabButtons: [OpaquePointer] = []
  /// One `GtkToggleButton` per type-filter chip: index 0 is "All"
  /// (`kindFilter == nil`), the rest index-aligned with `ItemKind.allCases`
  /// (index `i + 1`) — see `PickerWindow+Chips.swift`.
  var chipButtons: [OpaquePointer] = []

  /// The rows/snippets currently rendered — kept in the same order as
  /// `listBox`'s children so a `GtkListBoxRow`'s `gtk_list_box_row_get_index`
  /// indexes directly into whichever of these is live for the active tab
  /// (see `PickerWindow+Rows.swift`). Only one is ever non-empty at a time.
  var renderedRows: [ClipItem] = []
  var renderedSnippets: [Snippet] = []

  /// The GLib timeout source ID driving the poll-and-reconcile loop (see
  /// `PickerWindow+Polling.swift`), while the window is visible; `nil`
  /// while hidden.
  var pollSourceID: UInt32?
  var lastSnapshot: PickerPollSnapshot = .initial

  /// The pointer position of the most recent hover-preview motion event —
  /// where `PickerWindow+Preview.swift` anchors `previewPopover` via
  /// `gtk_popover_set_pointing_to`. `nil` until the first hover.
  var lastHoverPoint: GdkRectangle?

  /// Guards against `notify::is-active` firing `onDismiss` for the
  /// activation transition `show(at:)` itself causes (a freshly-presented
  /// window becomes active asynchronously; without this guard that
  /// transition could otherwise be misread as a focus change to dismiss
  /// on, on some window managers' timing). Set `true` at the start of
  /// `show(at:)`, cleared the first time the window is OBSERVED active.
  var isAwaitingInitialActivation = false

  public init(viewModel: PickerViewModel, onDismiss: @escaping () -> Void) {
    self.viewModel = viewModel
    self.onDismiss = onDismiss
    self.windowToken = UUID().uuidString

    window = gtk_window_new()
    searchEntry = gtk_search_entry_new()
    tabsBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.chipSpacing)
    chipsBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.chipSpacing)
    scrolledWindow = gtk_scrolled_window_new()
    listBox = gtk_list_box_new()
    loadingLabel = gtk_label_new("Loading…")
    footerLabel = gtk_label_new("")
    previewPopover = gtk_popover_new()
    previewImage = gtk_image_new()
    previewLabel = gtk_label_new("")

    gtk_window_set_title(window, windowToken)
    gtk_window_set_decorated(window, 0)
    gtk_window_set_resizable(window, 0)
    gtk_window_set_default_size(window, PickerWindow.defaultWidth, PickerWindow.defaultHeight)

    buildLayout()
    connectSignals()
  }

  /// Shows the picker: resets/re-focuses the search field, starts the
  /// `PickerViewModel` query pipeline (`willShow()`), starts the poll loop,
  /// and presents the window. `point` cannot be acted on here — see this
  /// file's top "WINDOW PLACEMENT" doc comment; it is accepted purely to
  /// match this task's API contract, so a caller doesn't need a
  /// Linux-specific overload.
  public func show(at point: (x: Int, y: Int)?) {
    _ = point
    isAwaitingInitialActivation = true
    MainActor.assumeIsolated {
      viewModel.willShow()
    }
    lastSnapshot = .initial
    startPolling()
    gtk_widget_set_visible(window, 1)
    gtk_window_present(window)
  }

  /// Hides the picker and stops the poll loop — mirrors `PickerPanel
  /// .orderOut`/`PickerViewModel.didHide()` on macOS.
  public func hide() {
    stopPolling()
    MainActor.assumeIsolated {
      viewModel.didHide()
    }
    gtk_widget_set_visible(window, 0)
  }
}
