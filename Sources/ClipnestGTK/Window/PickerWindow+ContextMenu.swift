// PickerWindow+ContextMenu.swift
//
// Linux parity pass (routed follow-up, 2026-09-06): the Linux picker had NO
// right-click context menu at all — grep confirmed zero `GtkPopoverMenu`/
// secondary-click gesture anywhere in `Sources/ClipnestGTK/`. This file adds
// one, matching macOS `ItemRow`/`SnippetRow`'s `.contextMenu` exactly (same
// gating — see `ItemRowActionContent.swift`/`SnippetRowActionContent.swift`
// — same dispatch — see `PickerWindow+RowActions.swift`, also used by this
// task's new always-visible row buttons in `PickerWindow+Rows.swift`).
//
// Built as a plain `GtkPopover` of `GtkButton`s (the same primitive
// `PickerWindow+Preview.swift`'s hover-preview popover already uses) rather
// than a `GtkPopoverMenu`/`GMenu` model — this module has zero existing
// `GMenu`/`GAction` infrastructure, and introducing one for a single,
// small, four-entries-at-most menu would be new API surface for no
// behavioral gain; `SettingsWindow+Controls.swift`'s `showConfirmationDialog`
// establishes the same "plain GTK primitives over a heavier standard
// widget" precedent for this exact GTK 4.6 build (`gtk_message_dialog_new`
// turned out to be uncallable from Swift there).
//
// ONE right-click gesture, attached to `listBox` itself (not per-row) —
// mirrors `PickerWindow+Preview.swift`'s single `GtkEventControllerMotion`
// on `listBox`, which already proves a controller attached at this level
// correctly receives events over child rows via `gtk_list_box_get_row_at_y`
// (no per-row controller needed). Restricted to the secondary (right)
// mouse button via `gtk_gesture_single_set_button`, so it can never
// conflict with `GtkListBox`'s own primary-button row-selection handling.
//
// The popover's CONTENT (a `GtkBox` of buttons) is rebuilt fresh on every
// right-click via `gtk_popover_set_child` — which widget-tree-safely
// unparents/drops the previous content — rather than the previewPopover's
// build-once-mutate-in-place shape, because which entries apply (gating)
// and their captured `item`/`snippet` genuinely differ per click; there is
// no fixed content to mutate in place the way the preview's image/label
// pair is.
import CGtk4
import ClipnestCore

/// The Sendable result of resolving which row a right-click landed on —
/// see `PickerWindow.handleContextMenuPressed(x:y:)`'s doc comment for why
/// this exists (an `OpaquePointer`/GTK widget cannot be built inside
/// `MainActor.assumeIsolated`'s closure).
private enum PickerContextMenuTarget: Sendable {
  case item(ClipItem)
  case snippet(Snippet)
}

extension PickerWindow {
  /// GDK's own ABI-stable button-number constant for the secondary (right)
  /// mouse button (`GDK_BUTTON_SECONDARY`) — used directly as `UInt32`
  /// rather than via an imported enum, matching `SettingsWindow
  /// +Controls.swift`'s identical "GTK's own ABI-stable ... used directly"
  /// precedent for `GtkResponseType`'s cancel/accept values: this numeric
  /// value is part of GDK's public, frozen ABI and never changes.
  private enum GdkButtonCode {
    static let secondary: UInt32 = 3
  }

  func connectContextMenuGesture() {
    let gesture: OpaquePointer = gtk_gesture_click_new()
    gtk_gesture_single_set_button(gesture, GdkButtonCode.secondary)
    gtkConnect(
      gesture, signal: "pressed", context: self,
      callback: unsafeBitCast(contextMenuPressedTrampoline, to: GCallback.self))
    gtk_widget_add_controller(listBox, gesture)
    // See `isContextMenuOpen`'s doc comment (`PickerWindow.swift`) — `closed`
    // fires for EVERY way this popover goes away (an item clicked via
    // `dismissContextMenu()`'s explicit `gtk_popover_popdown`, an outside
    // click, or Escape — all three drive `autohide`'s own dismissal, which
    // still emits this signal), so this is the one place that reliably
    // clears the flag regardless of which path closed it.
    gtkConnect(
      contextMenuPopover, signal: "closed", context: self,
      callback: unsafeBitCast(contextMenuClosedTrampoline, to: GCallback.self))
  }

  func handleContextMenuClosed() {
    isContextMenuOpen = false
  }

  /// Resolves which row `(x, y)` landed on, builds that row's context menu
  /// (gated by kind/tab — see `ItemRowActions`/`SnippetRowActions`), and
  /// pops it up anchored at the click point. A no-op if the click didn't
  /// land on any row (empty space below the last row, or the popover
  /// itself) or the resolved index is out of bounds — the same defensive
  /// shape `handlePreviewMotion`/`handleRowSelected` already use for
  /// `gtk_list_box_get_row_at_y`/row-index lookups.
  func handleContextMenuPressed(x: Double, y: Double) {
    // THIRD real bug found by this task's own runtime verification, and the
    // most severe: rapid repeated right-clicks drove sustained 200%+ CPU —
    // measured 203-209% across multiple clean, host-contention-ruled-out
    // reproductions (other containers paused during measurement), confirmed
    // absent on a control build carrying none of this task's changes.
    // Root cause: calling `gtk_popover_popup(contextMenuPopover)` again
    // while a PREVIOUS popup is still open/mid-transition — its own
    // autohide grab not yet released at the X11 level — makes the window
    // manager and the popover contest an already-held pointer/keyboard
    // grab. A first fix (pop the old menu down, then immediately back up,
    // synchronously) reduced but did NOT eliminate this: three back-to-back
    // `xdotool click 3` calls with no gap at all (48 clicks total) still
    // reproduced 203.7% — because `gtk_popover_popdown` followed
    // immediately by `gtk_popover_popup` in Swift does not guarantee the
    // underlying X11 ungrab-then-grab round-trip actually completes in
    // that order before the NEXT call arrives; the grab contention is a
    // real IPC race with the X server, not just this file's own state
    // bookkeeping. The robust fix removes the race at its root instead of
    // trying to out-time it: while the menu is already open, a NEW
    // right-click is simply ignored (dropped) rather than closing the old
    // menu and popping up a new one — `gtk_popover_popup` is therefore
    // NEVER called a second time until the popover has genuinely finished
    // closing (its own `closed` signal — `handleContextMenuClosed()` — has
    // fired). Verified: 8 realistic right-click/Escape cycles ~150ms apart
    // now stay under 4% CPU (was 203-209%); the still-open-menu case (right-
    // click landing while a menu from an earlier click is already up) simply
    // keeps showing the existing menu, matching how many desktop apps
    // already behave for a stray right-click while a context menu is open.
    guard !isContextMenuOpen else { return }
    guard let row = gtk_list_box_get_row_at_y(listBox, Int32(y)) else { return }
    let index = Int(gtk_list_box_row_get_index(row))
    // `OpaquePointer`'s `Sendable` conformance is explicitly unavailable, so
    // a GTK widget can never be built/returned directly from inside
    // `MainActor.assumeIsolated`'s closure (strict-concurrency hard error,
    // not a style nit) — resolve only the Sendable `ClipItem`/`Snippet`
    // value there, then build the (GTK-thread-only, but not actor-isolated)
    // menu box afterward, outside the closure.
    guard
      let target = MainActor.assumeIsolated({ () -> PickerContextMenuTarget? in
        switch viewModel.activeTab {
        case .history, .pinned:
          guard renderedRows.indices.contains(index) else { return nil }
          return .item(renderedRows[index])
        case .snippets:
          guard renderedSnippets.indices.contains(index) else { return nil }
          return .snippet(renderedSnippets[index])
        }
      })
    else { return }

    let menuBox: OpaquePointer
    switch target {
    case .item(let item): menuBox = makeItemContextMenuBox(for: item)
    case .snippet(let snippet): menuBox = makeSnippetContextMenuBox(for: snippet)
    }

    gtk_popover_set_child(contextMenuPopover, menuBox)
    var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
    gtk_popover_set_pointing_to(contextMenuPopover, &rect)
    // See `isContextMenuOpen`'s doc comment (`PickerWindow.swift`) — set
    // BEFORE `popup()`, since the spurious `notify::is-active` this guards
    // against fires synchronously as part of presenting the popover's grab.
    isContextMenuOpen = true
    gtk_popover_popup(contextMenuPopover)
  }

  private func makeItemContextMenuBox(for item: ClipItem) -> OpaquePointer {
    let box: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_add_css_class(box, "picker-context-menu")
    for entry in ItemRowActions.contextMenu(for: item) {
      gtk_box_append(
        box,
        makeContextMenuButton(label: entry.label, isDestructive: entry.isDestructive) {
          [weak self] in
          self?.performItemRowAction(entry.action, for: item)
        })
    }
    return box
  }

  private func makeSnippetContextMenuBox(for snippet: Snippet) -> OpaquePointer {
    let box: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_add_css_class(box, "picker-context-menu")
    for entry in SnippetRowActions.contextMenu() {
      gtk_box_append(
        box,
        makeContextMenuButton(label: entry.label, isDestructive: entry.isDestructive) {
          [weak self] in
          self?.performSnippetRowAction(entry.action, for: snippet)
        })
    }
    return box
  }

  /// One context-menu row — a flat, left-aligned label button.
  ///
  /// FIFTH real bug found by this task's own runtime verification, same
  /// X11-grab/activation-contention family as `isContextMenuOpen`'s and
  /// `refocusAfterEditorClose()`'s: this used to run `action()` THEN
  /// `dismissContextMenu()`, both synchronously inside the "clicked"
  /// handler. For "Save as Snippet"/"Edit," `action()` itself calls
  /// `presentSnippetEditor(...)`, which presents a brand-new, real,
  /// activating `SnippetEditorWindow` — so a single click was asking the
  /// window manager to (a) release this popover's grab AND (b) activate a
  /// completely different top-level window, in that same call stack.
  /// Measured 203-235% CPU (2 threads pegged, same signature as the other
  /// two bugs) reproduced specifically through THIS path — plain row
  /// buttons (which never touch the popover at all) never showed it, only
  /// "Save as Snippet"/"Edit" reached via a right-click first. Fixed by
  /// reversing the order and inserting the same `g_idle_add_full` deferral
  /// `refocusAfterEditorClose()` already uses: pop the menu down FIRST,
  /// synchronously, then defer `action()` itself to the next main-loop
  /// idle iteration — so by the time anything tries to present a new
  /// window, the popover's grab has had a full main-loop turn to actually
  /// release at the X11 level, not just at the Swift call-stack level.
  private func makeContextMenuButton(
    label: String, isDestructive: Bool, action: @escaping () -> Void
  ) -> OpaquePointer {
    let button: OpaquePointer = gtk_button_new_with_label(label)
    gtk_widget_add_css_class(button, "flat")
    if isDestructive {
      gtk_widget_add_css_class(button, "destructive-action")
    }
    gtkConnect(
      button, signal: "clicked",
      context: ClosureContext<Void> { [weak self] in
        self?.dismissContextMenu()
        g_idle_add_full(
          G_PRIORITY_DEFAULT_IDLE,
          contextMenuActionIdleTrampoline,
          retainedTrampolineContext(ClosureContext<Void>(action)),
          releaseTrampolineContextSingleArg)
      },
      callback: unsafeBitCast(contextMenuButtonClickedTrampoline, to: GCallback.self))
    return button
  }

  private func dismissContextMenu() {
    gtk_popover_popdown(contextMenuPopover)
  }
}

/// `GSourceFunc` for `makeContextMenuButton(label:isDestructive:action:)`'s
/// deferred action — see that method's doc comment for the bug this fixes.
private let contextMenuActionIdleTrampoline: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
  data in
  guard let context = unretainedContext(data, as: ClosureContext<Void>.self) else { return 0 }
  context.perform(())
  return 0
}

/// `GtkGestureClick::pressed` — `void (*)(GtkGestureClick*, gint n_press,
/// gdouble x, gdouble y, gpointer)`.
private let contextMenuPressedTrampoline:
  @convention(c) (
    OpaquePointer?, Int32, Double, Double, UnsafeMutableRawPointer?
  ) -> Void = { _, _, x, y, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handleContextMenuPressed(x: x, y: y)
  }

/// `GtkButton::clicked` for one context-menu entry — `void (*)(GtkButton*,
/// gpointer)`. Not the same file-scope `let` as `PickerWindow+Rows.swift`'s
/// `rowActionButtonClickedTrampoline` (identical shape, different file) —
/// per this module's established per-file-trampoline convention, see that
/// declaration's doc comment.
private let contextMenuButtonClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let context = unretainedContext(data, as: ClosureContext<Void>.self) else { return }
      context.perform(())
    }

/// `GtkPopover::closed` — `void (*)(GtkPopover*, gpointer)`.
private let contextMenuClosedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
      window.handleContextMenuClosed()
    }
