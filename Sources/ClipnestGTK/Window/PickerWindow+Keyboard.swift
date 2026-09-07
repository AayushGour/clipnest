// PickerWindow+Keyboard.swift
//
// P7-D (Linux port, GTK4 view layer): `connectSignals()` — the aggregator
// called once from `PickerWindow.init`, right after `buildLayout()` — plus
// the keyboard shortcut controller, the search entry's live-filter signal,
// and dismiss-on-focus-loss. `KeyEventMapping.action(keyval:state:)`
// (`Support/`) is the single source of truth for what a key press MEANS;
// this file only dispatches the resulting `PickerKeyAction` to the right
// `PickerViewModel`/GTK call.
//
// The key controller is attached to the WINDOW (not the search entry) with
// `GTK_PHASE_CAPTURE`, so it sees every key press BEFORE the focused
// widget's own default handling — otherwise a `GtkSearchEntry`'s internal
// Return/Escape bindings could consume the event before this picker's own
// shortcuts ever ran. Returning `1` (`GDK_EVENT_STOP`) only for keys
// `KeyEventMapping` actually binds lets every other key (ordinary typing)
// fall through to the search entry untouched.
//
// T-KBPARITY3 (Linux/macOS key-handling parity pass): this file used to
// special-case ONLY `.delete` (see `shouldPropagateToSearchEntry`'s doc
// comment below) with a coarse "is the search text non-empty" check. This
// task closes the remaining gap with macOS's real semantics — see that
// method's doc comment for what changed and why a literal
// `GTK_PHASE_BUBBLE` controller (the architecturally "natural" fix, and
// this task's starting hypothesis) turned out NOT to work, verified
// empirically rather than assumed.
import CGtk4
import ClipnestViewModels

extension PickerWindow {
  func connectSignals() {
    connectRowSignals()
    connectKeyController()
    connectSearchEntry()
    connectWindowActivation()
    connectPreviewMotion()
    // Linux parity pass (routed follow-up, 2026-09-06): the row right-click
    // context menu — see `PickerWindow+ContextMenu.swift`.
    connectContextMenuGesture()
  }

  private func connectKeyController() {
    let controller: OpaquePointer = gtk_event_controller_key_new()
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
    gtkConnect(
      controller, signal: "key-pressed", context: self,
      callback: unsafeBitCast(keyPressedTrampoline, to: GCallback.self))
    gtk_widget_add_controller(window, controller)
  }

  private func connectSearchEntry() {
    gtkConnect(
      searchEntry, signal: "search-changed", context: self,
      callback: unsafeBitCast(searchChangedTrampoline, to: GCallback.self))
  }

  /// `notify::is-active` — fires whenever this window's own active/focused
  /// state changes; used to implement "onDismiss fires ... when the window
  /// loses focus" (this task's API contract). `isAwaitingInitialActivation`
  /// (set in `show(at:)`) skips the very first observed transition so
  /// presenting the window doesn't immediately fire a spurious dismiss
  /// before it has ever actually been active.
  private func connectWindowActivation() {
    gtkConnect(
      window, signal: "notify::is-active", context: self,
      callback: unsafeBitCast(windowActiveChangedTrampoline, to: GCallback.self))
  }

  func handleKeyPressed(keyval: UInt32, state: UInt32) -> Int32 {
    guard let action = KeyEventMapping.action(keyval: keyval, state: state) else { return 0 }
    // P0 DATA LOSS, found by black-box testing on Ubuntu 22.04 and confirmed on
    // a clean HEAD build: typing in the search field and pressing Delete
    // permanently destroyed the highlighted clipboard item (measured: 4 rows ->
    // 3, no confirmation, no undo).
    //
    // This controller is attached at GTK_PHASE_CAPTURE, so it sees every key
    // BEFORE the focused widget does. That is required for the picker's own
    // chords (arrows, Ctrl-chords, Escape, Return) to work while the search
    // entry holds focus, which it does for most of the picker's life — see
    // `KeyEventMapping.swift`'s NOT-Delete cases and
    // `PickerKeyAction.isTextEditingKeyWhenTypingInSearch`'s doc comment for
    // why those six-plus actions are always safe to intercept unconditionally
    // (T-KBPARITY3 verified this empirically for the four keyboard-parity
    // additions specifically, since `Ctrl+Shift+E` was flagged as a chord
    // some input methods intercept: none of `Ctrl+S`/`Ctrl+N`/
    // `Ctrl+Shift+E`/`Ctrl+,` were ever consumed by a focused `GtkSearchEntry`
    // in a real GTK4/Ubuntu-22.04 run — a bubble-phase probe controller on
    // the same window still saw all four).
    //
    // Delete is the one exception — a focused `GtkText` (the search entry's
    // internal editable) DOES legitimately own it whenever pressing it would
    // edit the field's content. `Self.shouldPropagateToSearchEntry(action:
    // focusIsInSearchEntry:searchEntryEditWouldHaveEffect:)` (below) is the
    // pure decision, unit-tested exhaustively; `searchEntryDeleteWouldHaveEffect`
    // (also below) is the one place that still reads live GTK state
    // (`gtkFocusIsWithin`, the entry's caret position/selection) to feed it.
    //
    // T-KBPARITY3 (this task): macOS's `PickerView.handle(_:)` gets this for
    // free — SwiftUI's `.onKeyPress`, attached to the OUTER container, only
    // ever sees a key the focused `TextField` did NOT consume, so a
    // no-op forward-delete (caret already at the end of the text, nothing to
    // delete) bubbles up and the picker deletes the highlighted row instead
    // (see that file's own "Reliability note (T24)"). The previous Linux fix
    // (T-BB1/T-KBPARITY2) approximated this with a single check — "does the
    // search box have ANY text" — which got the empty-box case right but NOT
    // caret-at-the-end-of-non-empty-text: it always propagated Delete to the
    // entry whenever the box had text, so that specific case rang GTK's
    // error bell and never reached the picker, unlike macOS.
    //
    // The natural-looking fix is a second `GtkEventControllerKey` on this
    // same window at `GTK_PHASE_BUBBLE` instead of this capture-phase
    // special-case — "sees only what the focused widget didn't handle" is
    // exactly the bubbling `.onKeyPress` gets on macOS. VERIFIED, rather than
    // assumed, that this does NOT work: a throwaway GTK4 probe app (plain
    // `GtkSearchEntry`, one `GTK_PHASE_CAPTURE` + one `GTK_PHASE_BUBBLE`
    // `GtkEventControllerKey` on the window, Ubuntu 22.04's real
    // `libgtk-4-dev` 4.6.9, driven by `xdotool` under Xvfb) showed the bubble
    // controller NEVER receives a Delete keypress while the entry has focus,
    // in ANY state — caret mid-text (after really deleting a character),
    // caret at the end of non-empty text (a no-op — GTK still rings
    // `gtk_widget_error_bell` and swallows the event), and a completely empty
    // entry (also swallowed). `GtkText`'s Delete key binding is a
    // `G_SIGNAL_ACTION`; activating it counts as "handled" regardless of
    // whether it changed anything, so `gtk_propagate_event_internal` never
    // reaches a bubble-phase controller for that keypress at all. A literal
    // `GTK_PHASE_BUBBLE` controller would therefore make Delete NEVER reach
    // the picker while the search entry has focus — REGRESSING the
    // already-shipped, already-tested "empty search + Delete deletes the
    // highlighted item" behavior (T-BB1), not fixing anything. GTK genuinely
    // cannot reproduce macOS's bubble semantics for this key via its own
    // propagation mechanism.
    //
    // The closest safe equivalent: compute, right here at the capture-phase
    // interception point, the same predicate `GtkText`'s own
    // `gtk_text_delete_from_cursor` uses internally to decide whether a
    // forward-delete would do anything — an active selection, or a character
    // sitting after the caret — and use THAT (not "is the box non-empty") to
    // decide whether the entry legitimately owns this particular keypress.
    // The user-observable outcome matches macOS scenario-for-scenario (see
    // `docs/API-ClipnestGTK.md`'s keyboard-parity table); it's just decided
    // before dispatch instead of by GTK's own bubbling, because GTK's
    // bubbling can't do it.
    if Self.shouldPropagateToSearchEntry(
      action: action,
      focusIsInSearchEntry: gtkFocusIsWithin(window: window, widget: searchEntry),
      searchEntryEditWouldHaveEffect: Self.searchEntryDeleteWouldHaveEffect(searchEntry)
    ) {
      return 0  // GDK_EVENT_PROPAGATE — let the focused GtkEntry handle it
    }
    dispatch(action)
    return 1
  }

  /// Whether a mapped `PickerKeyAction` should be propagated to the focused
  /// search entry (`GDK_EVENT_PROPAGATE`) instead of being acted on by the
  /// picker — the pure decision behind `handleKeyPressed`'s P0 data-loss fix
  /// (see that method's doc comment for the full history, including why a
  /// literal `GTK_PHASE_BUBBLE` controller can't replace this), extracted so
  /// it's unit-testable without a live GTK widget tree/display. `static`,
  /// not an instance method: it touches no stored property of this class,
  /// only its three plain-value parameters — same reason
  /// `KeyEventMapping.action(keyval:state:)` is a `static func` on its own
  /// type.
  ///
  /// Requires BOTH `focusIsInSearchEntry` AND `searchEntryEditWouldHaveEffect`,
  /// and the second half is not redundant: `willShow()` focuses the search
  /// entry every time the picker opens, so a focus-only check would mean
  /// bare Delete never reached the list at all — measured, after a first
  /// attempt at this fix did exactly that (see `GTKPickerWindowKeyboardTests`
  /// for the pinned matrix, including that exact case).
  ///
  /// `searchEntryEditWouldHaveEffect` (computed by
  /// `searchEntryDeleteWouldHaveEffect(_:)`, below, from live GTK state) is
  /// true exactly when the search entry has a selection to remove, or a
  /// character sitting after the caret to forward-delete — i.e. when
  /// `GtkText`'s own Delete binding would actually change the entry's
  /// content, mirroring macOS's `TextField`, which likewise only consumes
  /// Delete when it has something to do. When it's false (caret already at
  /// the end of the text, with or without any text at all — an empty box is
  /// the degenerate case of "caret at the end"), there is nothing for Delete
  /// to edit, so the picker's own meaning (delete the highlighted item) is
  /// the only sensible one — matching macOS's documented bubble-through
  /// behavior for a no-op forward-delete.
  /// `action.isTextEditingKeyWhenTypingInSearch` (`PickerKeyAction.swift`) is
  /// checked first — only `.delete` ever qualifies today, so every other
  /// action (arrows, Ctrl-chords including the four keyboard-parity
  /// additions, commit, dismiss) always returns `false` here regardless of
  /// focus/text, i.e. the picker always acts on them even while the user is
  /// typing a search — deliberate, matching macOS (Cmd-chords/arrow-key
  /// navigation both keep working while a SwiftUI `TextField` has focus
  /// there too), and empirically confirmed for the four keyboard-parity
  /// additions specifically (see `handleKeyPressed`'s doc comment).
  static func shouldPropagateToSearchEntry(
    action: PickerKeyAction,
    focusIsInSearchEntry: Bool,
    searchEntryEditWouldHaveEffect: Bool
  ) -> Bool {
    guard action.isTextEditingKeyWhenTypingInSearch else { return false }
    guard focusIsInSearchEntry else { return false }
    return searchEntryEditWouldHaveEffect
  }

  /// Reads the two live GTK values `shouldPropagateToSearchEntry` needs but
  /// can't read itself (kept pure/testable — see that method's doc comment)
  /// to decide whether the search entry's Delete key binding would actually
  /// change its content right now: an active selection (removed wholesale,
  /// same as macOS's `TextField` deleting a selection), or a character
  /// sitting after the caret (a real forward-delete). Mirrors
  /// `gtk_text_delete_from_cursor`'s own no-selection/no-effect check inside
  /// GTK itself (see `handleKeyPressed`'s doc comment for how that was
  /// confirmed, not assumed) rather than re-deriving it from the entry's
  /// text content in Swift, so this can never disagree with what GTK is
  /// about to do.
  ///
  /// `g_utf8_strlen`, not `searchText.count`: `gtk_editable_get_position`
  /// documents its return value as a CHARACTER offset (not a byte offset,
  /// which matters for any non-ASCII search text), and `g_utf8_strlen`
  /// counts in the same unit GTK does — Swift's `String.count` counts
  /// grapheme clusters instead, which can disagree with GTK's per-codepoint
  /// count for combining sequences/emoji, exactly the kind of silent
  /// off-by-one this predicate cannot afford.
  private static func searchEntryDeleteWouldHaveEffect(_ searchEntry: OpaquePointer) -> Bool {
    var selectionStart: Int32 = 0
    var selectionEnd: Int32 = 0
    if gtk_editable_get_selection_bounds(searchEntry, &selectionStart, &selectionEnd) != 0 {
      return true
    }
    let caretPosition = gtk_editable_get_position(searchEntry)
    let characterCount = g_utf8_strlen(gtk_editable_get_text(searchEntry), -1)
    return Int(caretPosition) < Int(characterCount)
  }

  /// Dispatches one mapped `PickerKeyAction` — see `PickerKeyAction.swift`'s
  /// doc comment for why this enum, not a raw keyval, is what every caller
  /// switches over.
  private func dispatch(_ action: PickerKeyAction) {
    switch action {
    case .moveUp:
      MainActor.assumeIsolated { viewModel.moveSelection(by: -1) }
    case .moveDown:
      MainActor.assumeIsolated { viewModel.moveSelection(by: 1) }
    case .commit(let plainText):
      MainActor.assumeIsolated { viewModel.selectHighlighted(plainText: plainText) }
    case .dismiss:
      dismiss()
    case .focusSearch:
      gtk_widget_grab_focus(searchEntry)
    case .togglePin:
      MainActor.assumeIsolated { viewModel.togglePinHighlighted() }
    case .delete:
      MainActor.assumeIsolated { viewModel.deleteHighlighted() }
    case .switchTab(let index):
      guard tabButtons.indices.contains(index.rawValue - 1) else { return }
      gtk_toggle_button_set_active(tabButtons[index.rawValue - 1], 1)
    case .saveAsSnippet:
      // Mirrors macOS's ⌘S key handler exactly: no tab/kind gate here —
      // `saveHighlightedAsSnippet()` already no-ops on the Snippets tab and
      // for a highlighted row whose kind doesn't support it (see that
      // method's own doc comment).
      MainActor.assumeIsolated { viewModel.saveHighlightedAsSnippet() }
    case .newSnippet:
      // Mirrors macOS's ⌘N key handler: `presentCreateSnippetForm()` itself
      // has no tab guard (unlike `saveHighlightedAsSnippet()` above), so the
      // Snippets-tab-only gate lives here, matching `PickerView.handle(_:)`'s
      // `guard viewModel.activeTab == .snippets else { return .ignored }`.
      MainActor.assumeIsolated {
        guard viewModel.activeTab == .snippets else { return }
        viewModel.presentCreateSnippetForm()
      }
    case .replaceSnippet:
      // Opens the edit form for the highlighted snippet — the same
      // `presentEditSnippetForm(_:)` a Snippets-tab row's "Edit" hover
      // button/context-menu item already calls
      // (`PickerWindow+RowActions.swift`). Unlike macOS, this has no global
      // ⌥⌘E analogue to defer to: macOS's ⌥⌘E is `SnippetExpander`'s
      // system-wide "replace the OS-level text selection with a snippet's
      // body" hotkey, registered outside the picker entirely
      // (`HotkeyManager`/`AppEnvironment.swift`) — it does not open this
      // edit form and has no notion of "the highlighted row." `PickerView`'s
      // own key handler has no ⌥⌘E case at all. `presentEditSnippetForm(_:)`
      // takes a concrete `Snippet`, and `PickerViewModel.highlightedSnippet`
      // is `private` (not reachable from this module) — so the lookup below
      // mirrors the exact `snippetRows.first { $0.id == id }` pattern
      // `PickerView.swift`'s own `.onChange(of: previewTargetID)` already
      // uses against the same public `snippetRows`/`selectedSnippetID`,
      // rather than adding a new `PickerViewModel` method for this one
      // dispatch site. A no-op off the Snippets tab or with nothing
      // highlighted, mirroring `saveHighlightedAsSnippet()`/
      // `deleteHighlighted()`'s own "guard ... else return" shape for an
      // absent highlighted row.
      MainActor.assumeIsolated {
        guard viewModel.activeTab == .snippets,
          let id = viewModel.selectedSnippetID,
          let snippet = viewModel.snippetRows.first(where: { $0.id == id })
        else { return }
        viewModel.presentEditSnippetForm(snippet)
      }
    case .openSettings:
      // Mirrors macOS's ⌘, (`PickerPanel.onCommandComma` ->
      // `viewModel.openSettingsFromPicker()`): dismisses the picker, then
      // calls `viewModel.openSettings` — wired, on Linux, by the composition
      // root (`LinuxAppEnvironment.init`) to `self.openSettings()` (the same
      // method the tray/D-Bus "Settings…" entry already calls), exactly as
      // `PickerView.swift`'s `.onAppear` wires it on macOS to
      // `openSettings()` + `SettingsFocusCoordinator.focusAfterOpening()`.
      MainActor.assumeIsolated { viewModel.openSettingsFromPicker() }
    }
  }

  func handleSearchChanged() {
    let text = String(cString: gtk_editable_get_text(searchEntry))
    MainActor.assumeIsolated {
      viewModel.searchTextChanged(text)
    }
  }

  func handleWindowActiveChanged() {
    guard gtk_window_is_active(window) == 0 else {
      isAwaitingInitialActivation = false
      return
    }
    guard !isAwaitingInitialActivation else { return }
    // Linux parity pass (routed follow-up, 2026-09-06), real bug found by
    // this task's own runtime verification: see `isContextMenuOpen`'s doc
    // comment (`PickerWindow.swift`) — the right-click context menu's
    // implicit autohide grab fires this exact `notify::is-active`
    // transition, indistinguishable here from a genuine focus loss to a
    // different application, without this guard.
    guard !isContextMenuOpen else { return }
    // Linux parity pass (routed follow-up, 2026-09-06), a second real bug
    // in the same family: see `isEditorSessionActive`'s doc comment
    // (`PickerWindow.swift`) — presenting `SnippetEditorWindow` also fires
    // this exact transition (window-manager focus genuinely moves to that
    // window), which used to fully dismiss the picker instead of just
    // losing window-manager prominence, unlike macOS's side-by-side
    // non-dismissing design.
    guard !isEditorSessionActive else { return }
    dismiss()
  }
}

/// `GtkEventControllerKey::key-pressed` — `gboolean (*)(GtkEventControllerKey*,
/// guint keyval, guint keycode, GdkModifierType state, gpointer)`.
private let keyPressedTrampoline:
  @convention(c) (
    OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?
  ) -> Int32 = { _, keyval, _, state, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return 0 }
    return window.handleKeyPressed(keyval: keyval, state: state)
  }

/// `GtkSearchEntry::search-changed` — `void (*)(GtkSearchEntry*, gpointer)`.
private let searchChangedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
      window.handleSearchChanged()
    }

/// `notify::is-active` — GObject's generic `notify` signal:
/// `void (*)(GObject*, GParamSpec*, gpointer)`.
private let windowActiveChangedTrampoline:
  @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { _, _, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handleWindowActiveChanged()
  }
