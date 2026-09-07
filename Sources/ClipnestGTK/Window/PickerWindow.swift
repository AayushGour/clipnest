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
// window_token, x, y, flags)` D-Bus method, the GNOME Shell extension finds
// this exact window and moves/raises/stickies it directly through Mutter —
// a capability only the compositor has. `ClipnestLinuxApp` (a different
// agent's scope) is expected to call that D-Bus method with the SAME point
// passed to `show(at:)`, using `windowToken` — `show(at:)` accepts `point`
// to match this task's API contract exactly, but cannot itself act on it;
// see that method's doc comment.
//
// T-RT3: `windowToken` is `PickerWindow.role` ("picker"), a stable constant
// — NOT a fresh UUID per instance, as before. Two reasons landed together:
// (1) this window's title (`PickerWindow.displayTitle`, "Clipnest") is now
// human-readable rather than the raw token, because Alt-Tab, window lists,
// taskbars and screen readers all display it; and (2)
// `extension/src/core/placement.js`'s `_findByToken` no longer matches on
// `win.get_title() == token` at all (a different agent's concurrent change,
// same session) — it matches by `WM_CLASS` (`clipnest`, set via
// `g_set_prgname` before `gtk_init()`, T-RT1) plus this window's role, so
// `windowToken` never needs to be unique across invocations/windows for
// that lookup to work. The `PlaceWindow`/`UnplaceWindow` D-Bus wire
// contract (`windowToken: String`) is unchanged — only the VALUE passed
// through it changed, from a random UUID to this fixed role string.
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
// P10-D: `ClipnestObservation` is only ever built as a transitive dependency
// of `ClipnestViewModels` (never a direct `ClipnestGTK` target dependency in
// `Package.swift` — this file already imports `ClipnestCore` the exact same
// transitive way, see immediately above), but `ObservationCancellable` (the
// handle `objectWillChange.subscribe(_:)` returns, stored below) is one of
// its public types. `ClipnestGTK` only ever builds on Linux (see
// `Package.swift`'s `#if os(Linux)` guard around this whole target), where
// `Combine` never exists, so this import needs no `#if canImport(Combine)`
// guard the way `PickerViewModel.swift`'s does.
import ClipnestObservation
import ClipnestViewModels

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

  /// T-RT3: `windowToken`'s value — a stable per-ROLE constant, not a
  /// fresh UUID per instance. See this file's top "WINDOW PLACEMENT" doc
  /// comment for the full rationale and the extension-side contract this
  /// coordinates with.
  static let role = "picker"

  /// T-RT3: this window's user-visible title. Alt-Tab, window lists,
  /// taskbars and screen readers all announce this — it used to be the raw
  /// `windowToken` UUID (e.g. "77A26B3C-A233-49FA-B830-C9DCA7F153B1").
  /// Mirrors `SettingsWindow`'s own literal "Clipnest Settings" title
  /// (`SettingsWindow.swift`) one level up the naming, not shared via a
  /// constant with that file since it isn't in this task's file scope.
  static let displayTitle = "Clipnest"

  let viewModel: PickerViewModel
  let onDismiss: () -> Void
  public let windowToken: String

  // MARK: - Widgets (built by `buildLayout()`, `PickerWindow+Layout.swift`)

  let window: OpaquePointer

  /// The picker's underlying `GtkWindow`, exposed so a dialog opened FROM the
  /// picker can declare itself transient-for it. Required because the picker
  /// sets `_NET_WM_WINDOW_TYPE_UTILITY` on itself, and window managers stack
  /// utility windows above ordinary toplevels — a dialog that does not name
  /// the picker as its parent renders behind it. See
  /// `SnippetEditorWindow.show(mode:transientParent:onSave:onClose:)`.
  public var transientParentWindow: OpaquePointer { window }
  let searchEntry: OpaquePointer
  let tabsBox: OpaquePointer
  let chipsBox: OpaquePointer
  let scrolledWindow: OpaquePointer
  let listBox: OpaquePointer
  let loadingLabel: OpaquePointer
  /// T-RT5: shown in place of `scrolledWindow`/`listBox` whenever the
  /// active tab has zero rows to show and no query is in flight — see
  /// `PickerWindow+Reconcile.swift`'s `updateContentVisibility(snapshot:)`
  /// and `PickerWindow+EmptyState.swift`'s `emptyStateMessage(for:queryText:)`
  /// for the message text (kept in wording-parity with macOS's
  /// `PickerView.emptyStateMessage`). Built the same way as `loadingLabel`
  /// immediately below (hidden by default, shown/hidden only by that
  /// reconcile step).
  let emptyStateLabel: OpaquePointer
  let footerLabel: OpaquePointer
  let previewPopover: OpaquePointer
  let previewImage: OpaquePointer
  let previewLabel: OpaquePointer
  /// `.file`-only metadata rows, below `previewLabel`'s filename headline —
  /// mirrors macOS `ItemPreview.FilePreview`'s size + abbreviated-path
  /// lines. Hidden for every other kind — see `PickerWindow+Preview.swift`'s
  /// `updateFilePreviewMetadata(isFile:item:path:)`.
  let previewFileSizeLabel: OpaquePointer
  let previewFilePathLabel: OpaquePointer
  /// The recognized-text section shown BELOW an `.image` preview when
  /// `ClipItem.hasRecognizedText` — mirrors macOS `ItemPreview.imagePreview`
  /// (T-OCR2 parity). All three hidden together whenever the hovered item
  /// has no recognized text — see `PickerWindow+Preview.swift`'s
  /// `updateOCRSection(content:)`.
  let previewOCRSeparator: OpaquePointer
  let previewOCRHeaderLabel: OpaquePointer
  let previewOCRTextLabel: OpaquePointer
  /// Linux parity pass (routed follow-up, 2026-09-06): the row right-click
  /// context menu — built once, parented to `listBox` in `buildLayout()`
  /// (mirrors `previewPopover`'s lifetime exactly), with its CONTENT
  /// (a fresh `GtkBox` of buttons) swapped out per right-click via
  /// `gtk_popover_set_child` — see `PickerWindow+ContextMenu.swift`.
  let contextMenuPopover: OpaquePointer

  /// Linux parity pass (routed follow-up, 2026-09-06), third gap found
  /// while wiring the snippet editor: `PickerViewModel.presentCreateSnippetForm()`
  /// had NO entry point anywhere on Linux — `presentSaveAsSnippetForm(from:)`
  /// (via a History/Pinned row's action) only ever opens `.createFromClip`,
  /// never a truly blank `.create` form, so there was no way to author a
  /// brand-new snippet from scratch. Mirrors macOS `PickerView.tabBar`'s
  /// trailing `"plus.circle.fill"` button: visible ONLY while the Snippets
  /// tab is active — see `PickerWindow+Chips.swift`'s `buildTabs()`/
  /// `handleTabToggled(tab:isActive:)`.
  let newSnippetButton: OpaquePointer

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

  /// P10-D: the live subscription to `PickerViewModel.objectWillChange`
  /// (see `PickerWindow+Reconcile.swift`'s `startObservingChanges()`),
  /// while the window is visible; `nil` while hidden. Replaces the former
  /// `pollSourceID` (a recurring 33ms `GLib` timeout) — this is a push
  /// subscription instead, not a polling source.
  var changeSubscription: ObservationCancellable?

  /// The `g_idle_add_full` source ID for a coalesced reconcile that hasn't
  /// run yet (see `PickerWindowRefreshCoalescer`/`scheduleCoalescedRefresh()`
  /// in `PickerWindow+Reconcile.swift`); `nil` whenever none is pending.
  var pendingRefreshSourceID: UInt32?

  /// Collapses any number of `objectWillChange` notifications arriving
  /// before the next reconcile actually runs into exactly one
  /// `g_idle_add_full` call — see `PickerWindowRefreshCoalescer.swift`'s
  /// doc comment.
  let refreshCoalescer = PickerWindowRefreshCoalescer()

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

  /// Linux parity pass (routed follow-up, 2026-09-06), REAL BUG found by
  /// this task's own runtime verification: `contextMenuPopover`'s
  /// `autohide` (default `TRUE` — see `buildContextMenuPopover()`'s doc
  /// comment) makes GTK take an implicit pointer/keyboard grab while it's
  /// showing, so it can detect an outside click to auto-dismiss itself.
  /// Under Xvfb+Openbox (this task's own container test harness), that grab
  /// makes `window`'s OWN `notify::is-active` fire `false` the instant the
  /// menu pops up — indistinguishable, from `handleWindowActiveChanged()`'s
  /// prior code, from the picker genuinely losing focus to a DIFFERENT
  /// application, which dismissed the whole picker on every right-click
  /// (reproduced: `wmctrl -l` no longer listed the window at all
  /// immediately after a right-click, with no button even clicked yet).
  /// Set `true` right before `gtk_popover_popup(contextMenuPopover)`
  /// (`PickerWindow+ContextMenu.swift`), cleared on the popover's own
  /// `closed` signal (fires for every dismissal path: an item clicked, an
  /// outside click, or Escape) — mirrors `isAwaitingInitialActivation`'s
  /// exact shape for an analogous "ignore this transition, it's ours"
  /// need. Does not touch `dismiss()`/`isDismissing` themselves — this
  /// guards the DECISION to call `dismiss()` in the first place, made in
  /// `handleWindowActiveChanged()`.
  var isContextMenuOpen = false

  /// Linux parity pass (routed follow-up, 2026-09-06), SECOND real bug
  /// found by this task's own runtime verification, same root cause class
  /// as `isContextMenuOpen` but a different trigger: presenting
  /// `SnippetEditorWindow` (a real, separate, activating `GtkWindow` — see
  /// that type's top doc comment for why that's correct, unlike the
  /// non-activating picker) makes THIS window's `notify::is-active` fire
  /// `false` too, since window-manager focus genuinely moves to a different
  /// top-level surface. Before this flag, `handleWindowActiveChanged()`
  /// could not tell that apart from a real focus loss to some OTHER
  /// application, and called `dismiss()` — which does not just lose visual
  /// prominence, it fully hides the window and cancels the view model's
  /// in-flight queries (`viewModel.didHide()`), which then made
  /// `refocusAfterEditorClose()`'s own `gtk_widget_get_visible(window) != 0`
  /// guard silently no-op once the editor closed, leaving the picker
  /// closed after every "Save as Snippet"/edit/create — a real, reproduced
  /// regression relative to macOS, where the picker and editor coexist
  /// side by side and the picker is never dismissed by opening the editor.
  /// Set by the composition root via `setEditorSessionActive(_:)` around
  /// every `SnippetEditorWindow.show(...)` call (`LinuxAppEnvironment
  /// .presentSnippetEditor`) — `true` just before `show`, `false` at the
  /// very start of `onClose`, before `refocusAfterEditorClose()` runs. Not
  /// `private`: `PickerWindow+Keyboard.swift`'s `handleWindowActiveChanged()`
  /// (a different file — Swift's `private` is file-scoped) reads this;
  /// mirrors `isContextMenuOpen`/`isAwaitingInitialActivation`'s identical
  /// default (internal) access just above.
  var isEditorSessionActive = false

  /// True only for the duration of `dismiss()` — see its re-entrancy guard.
  private var isDismissing = false

  public init(viewModel: PickerViewModel, onDismiss: @escaping () -> Void) {
    self.viewModel = viewModel
    self.onDismiss = onDismiss
    self.windowToken = PickerWindow.role

    window = gtk_window_new()
    searchEntry = gtk_search_entry_new()
    tabsBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.chipSpacing)
    chipsBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.chipSpacing)
    scrolledWindow = gtk_scrolled_window_new()
    listBox = gtk_list_box_new()
    loadingLabel = gtk_label_new("Loading…")
    emptyStateLabel = gtk_label_new("")
    footerLabel = gtk_label_new("")
    previewPopover = gtk_popover_new()
    previewImage = gtk_image_new()
    previewLabel = gtk_label_new("")
    previewFileSizeLabel = gtk_label_new("")
    previewFilePathLabel = gtk_label_new("")
    previewOCRSeparator = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
    previewOCRHeaderLabel = gtk_label_new("Recognized Text")
    previewOCRTextLabel = gtk_label_new("")
    contextMenuPopover = gtk_popover_new()
    newSnippetButton = gtk_button_new_from_icon_name("list-add")

    gtk_window_set_title(window, PickerWindow.displayTitle)
    gtk_window_set_decorated(window, 0)
    gtk_window_set_resizable(window, 0)
    gtk_window_set_default_size(window, PickerWindow.defaultWidth, PickerWindow.defaultHeight)
    // Visual-parity pass (see `PickerStyleSheet.swift`): the window's own
    // CSS node carries the translucent-"material" background + rounded
    // corners approximating macOS's `PickerPanel`/`.regularMaterial` look —
    // but ONLY when the display actually composites. Without a compositor,
    // an alpha-clipped rounded corner has nothing to blend against and
    // renders as a solid BLACK wedge (X11's raw, uncomposited framebuffer
    // shows a transparent pixel's RGB bits directly, which GTK writes as
    // black) — strictly worse than the plain square corners this task is
    // trying to move away from. `picker-window-flat` is the deliberate,
    // GTK-idiomatic fallback (mirrors GTK's own CSD, which drops its
    // shadow/rounding via `.solid-csd` under the identical condition —
    // see `gtk_window_is_composited`/`GDK_AVAILABLE_IN_ALL gdk_display_is
    // _composited`): opaque fill, square corners, no clipping to go wrong.
    let isComposited = gdk_display_get_default().map { gdk_display_is_composited($0) != 0 } ?? false
    gtk_widget_add_css_class(window, isComposited ? "picker-window" : "picker-window-flat")
    // T-RT4: must happen before this window is ever presented/mapped —
    // mutter reads `_NET_WM_WINDOW_TYPE` at PLACEMENT time (this window's
    // first map, in `show(at:)`). A pure no-op under Wayland; see
    // `gtkWindowSetX11UtilityTypeHint(_:)`'s doc comment.
    gtkWindowSetX11UtilityTypeHint(window)

    buildLayout()
    connectSignals()
  }

  /// Shows the picker: starts observing `PickerViewModel.objectWillChange`
  /// (P10-D — replaces the old 33ms poll loop; see
  /// `PickerWindow+Reconcile.swift`), resets/re-focuses the search field
  /// and starts the query pipeline (`willShow()`), renders the resulting
  /// first frame immediately, and presents the window. `point` cannot be
  /// acted on here — see this file's top "WINDOW PLACEMENT" doc comment; it
  /// is accepted purely to match this task's API contract, so a caller
  /// doesn't need a Linux-specific overload.
  ///
  /// Order matters: observing starts BEFORE `willShow()` runs, because
  /// `willShow()` itself synchronously mutates several `@Published`
  /// properties — subscribing afterward would miss every one of them (see
  /// `startObservingChanges()`'s doc comment). `reconcileFromCurrentState()`
  /// then runs once, synchronously, right here — `lastSnapshot` was just
  /// reset to `.initial`, so this renders a complete first frame
  /// immediately rather than waiting for the coalesced idle callback
  /// `willShow()`'s mutations already scheduled (that callback still runs
  /// shortly after; it harmlessly finds nothing left to change).
  public func show(at point: (x: Int, y: Int)?) {
    _ = point
    isAwaitingInitialActivation = true
    lastSnapshot = .initial
    startObservingChanges()
    MainActor.assumeIsolated {
      viewModel.willShow()
    }
    reconcileFromCurrentState()
    gtk_widget_set_visible(window, 1)
    gtk_window_present(window)
  }

  /// The single dismissal path: hides the window AND tells the owner it is
  /// gone. Every user-initiated dismissal (Esc, losing focus, selecting a
  /// row) must route through here rather than calling `hide()` or
  /// `onDismiss()` alone.
  ///
  /// Those two used to be reachable independently, and each half-dismissal
  /// was a real, runtime-verified bug on Ubuntu 22.04:
  ///
  /// - `onDismiss()` without `hide()` — what `Esc` and `notify::is-active`
  ///   both did — left the window mapped and on screen while
  ///   `PickerViewModel.isVisible` went `false`. Esc simply did not close
  ///   the picker; worse, the still-visible window was inert, because
  ///   `isVisible == false` makes `handleNewCapture()` and
  ///   `handleExternalStoreChange()` both return early and `didHide()`
  ///   cancels every in-flight query. That is the actual cause of T-RT2:
  ///   Clear All History emptied the store and correctly broadcast
  ///   `.clearedAll`, the picker received it, and dropped it on the
  ///   `isVisible` guard — so a picker sitting in front of the user kept
  ///   rendering deleted items.
  /// - `hide()` without `onDismiss()` — what `PickerViewModel.dismiss` did
  ///   after a paste — hid the window but left the owner's visibility flag
  ///   `true`, so the next hotkey press ran the "hide" half of the toggle
  ///   against an already-hidden window and appeared to do nothing.
  ///
  /// `onDismiss` must therefore NOT call `didHide()` itself; `hide()` below
  /// already does, on the GTK thread, before this returns.
  public func dismiss() {
    // Re-entrancy guard, not defensive padding — without it this recurses
    // until the process pegs a core (measured: 156% CPU on Ubuntu 22.04).
    // `hide()` calls `gtk_widget_set_visible(window, 0)`, which makes the
    // window inactive, which fires `notify::is-active`, whose handler calls
    // `dismiss()` again. The `isAwaitingInitialActivation` flag does not
    // cover this: it only suppresses the FIRST transition after `show(at:)`.
    guard !isDismissing else { return }
    isDismissing = true
    defer { isDismissing = false }
    hide()
    onDismiss()
  }

  /// Hides the picker and stops observing/cancels any pending reconcile —
  /// mirrors `PickerPanel.orderOut`/`PickerViewModel.didHide()` on macOS.
  /// Prefer `dismiss()` for anything user-initiated — see its doc comment.
  public func hide() {
    stopObservingChanges()
    MainActor.assumeIsolated {
      viewModel.didHide()
    }
    gtk_widget_set_visible(window, 0)
  }

  /// Linux parity pass (routed follow-up, 2026-09-06): called by the
  /// composition root once `SnippetEditorWindow` (GTK) closes — the exact
  /// counterpart of `AppEnvironment`'s macOS `onClose: { panel.makeKey();
  /// viewModel.refocusSearchField() }` (`ClipnestApp/Sources/App
  /// /AppEnvironment.swift`). Presenting the snippet editor there makes IT
  /// key (a real, activating window) exactly like `gtk_window_present` does
  /// here, so on close this window needs to explicitly take input focus
  /// back — `viewModel.refocusSearchField()` alone only bumps `focusToken`,
  /// which `PickerWindow+Reconcile.swift`'s `gtk_widget_grab_focus
  /// (searchEntry)` only re-asserts focus *within* this window, not across
  /// the window manager.
  ///
  /// FOURTH real bug found by this task's own runtime verification, same
  /// root-cause family as `isContextMenuOpen`'s (X11 grab/focus contention
  /// under Xvfb+Openbox) but a different trigger: calling
  /// `gtk_window_present(window)` HERE — synchronously, inside
  /// `SnippetEditorWindow`'s own `close-request` handler, itself invoked
  /// synchronously from `gtk_window_close` (see `SnippetEditorWindow
  /// .handleSaveClicked()`/`.handleCancelClicked()`) — asks the window
  /// manager to activate this window in the SAME call stack that is still
  /// asking it to close/hide a DIFFERENT one, before that close has
  /// actually been processed. Measured: two `clipnest` threads each pegged
  /// (~110% apiece, ~225% total) after a single, unhurried Save — no rapid
  /// clicking needed this time, confirming the hazard is the SYNCHRONOUS
  /// close-then-present handoff itself, not click cadence. Fixed by
  /// deferring the present/refocus (and clearing `isEditorSessionActive`)
  /// to the next GLib main-loop idle iteration via `g_idle_add_full` — the
  /// same deferral primitive `PickerWindow+Reconcile.swift`'s
  /// `scheduleCoalescedRefresh()` already uses for an unrelated reason,
  /// giving the window manager a real chance to finish the editor's close
  /// before this window asks to be presented. A no-op when this window
  /// isn't currently visible (mirrors `AppEnvironment`'s own `guard panel
  /// .isVisible` for the identical call) — e.g. the picker was dismissed
  /// for some other reason while the editor was still open.
  public func refocusAfterEditorClose() {
    g_idle_add_full(
      G_PRIORITY_DEFAULT_IDLE,
      refocusAfterEditorCloseIdleTrampoline,
      retainedTrampolineContext(self),
      releaseTrampolineContextSingleArg)
  }

  /// The actual work `refocusAfterEditorClose()` defers — see that method's
  /// doc comment. Also where `isEditorSessionActive` is cleared (moved out
  /// of the composition root's separate `setEditorSessionActive(_:)` call —
  /// see that method's doc comment for why clearing it early, before this
  /// deferred step runs, would reopen the exact `notify::is-active` window
  /// this flag exists to close).
  // `fileprivate`, not `private`: the idle trampoline below is a top-level
  // (non-member) function in this same file, and Swift's `private` only
  // reaches an enclosing declaration's own extensions, not top-level code —
  // `fileprivate` is the one that actually grants file-wide access.
  fileprivate func performRefocusAfterEditorClose() {
    isEditorSessionActive = false
    guard gtk_widget_get_visible(window) != 0 else { return }
    gtk_window_present(window)
    MainActor.assumeIsolated {
      viewModel.refocusSearchField()
    }
  }

  /// Linux parity pass (routed follow-up, 2026-09-06): see
  /// `isEditorSessionActive`'s doc comment for the real bug this exists to
  /// fix. Called by the composition root (`LinuxAppEnvironment
  /// .presentSnippetEditor`) with `true` right before every
  /// `SnippetEditorWindow.show(...)` call — public because
  /// `SnippetEditorWindow`/`LinuxAppEnvironment` live in different modules
  /// from this type. The `false` half is no longer a separate call the
  /// composition root makes — see `performRefocusAfterEditorClose()`.
  public func setEditorSessionActive(_ active: Bool) {
    isEditorSessionActive = active
  }
}

/// `GSourceFunc` (`gboolean (*)(gpointer)`) for `refocusAfterEditorClose()`'s
/// deferred idle callback — `0` (`G_SOURCE_REMOVE`), matching
/// `PickerWindow+Reconcile.swift`'s `idleRefreshTrampoline`'s identical
/// one-shot shape, since this should never repeat.
private let refocusAfterEditorCloseIdleTrampoline:
  @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return 0 }
    window.performRefocusAfterEditorClose()
    return 0
  }
