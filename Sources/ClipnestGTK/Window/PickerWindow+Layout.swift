// PickerWindow+Layout.swift
//
// P7-D (Linux port, GTK4 view layer): widget-tree construction, called once
// from `PickerWindow.init`. Pure GTK-widget wiring — no `PickerViewModel`
// reads/writes here (those happen once `connectSignals()`, `PickerWindow
// +Rows.swift`'s rebuild functions, and `PickerWindow+Reconcile.swift`'s
// reconcile run — P10-D renamed this from the old poll loop, see that
// file's doc comment) — kept separate from `connectSignals()`
// (`PickerWindow+Keyboard.swift`/`+Rows.swift`/`+Chips.swift`/`+Preview.swift`)
// so this file answers only "what does the window look like," not "what
// does it do."
//
// Tree:
//   window
//     └─ outerBox (vertical)
//          ├─ searchEntry
//          ├─ chipsBox (horizontal — type-filter chips)
//          ├─ tabsBox (horizontal — History/Pinned/Snippets)
//          ├─ scrolledWindow
//          │    └─ listBox
//          ├─ loadingLabel               (shown instead of scrolledWindow
//          │                              while `isSearching` — see
//          │                              PickerWindow+Reconcile.swift)
//          ├─ emptyStateLabel            (T-RT5: shown instead of
//          │                              scrolledWindow when the active
//          │                              tab has zero rows and no query
//          │                              is in flight — see
//          │                              PickerWindow+Reconcile.swift's
//          │                              updateContentVisibility(snapshot:))
//          └─ footerLabel                (ShortcutHints text)
//   previewPopover (parented to listBox, NOT part of the tree above —
//                    GtkPopover manages its own floating surface)
//        └─ previewBox (vertical)
//             ├─ previewImage
//             └─ previewLabel
//   contextMenuPopover (Linux parity pass, 2026-09-06 — also parented to
//                    listBox, same reasoning as previewPopover; its content
//                    box is built fresh per right-click, not built once
//                    here — see PickerWindow+ContextMenu.swift)
import CGtk4

extension PickerWindow {
  static let outerSpacing: Int32 = 8
  static let chipSpacing: Int32 = 4
  static let outerMargin: Int32 = 8

  func buildLayout() {
    let outerBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.outerSpacing)
    gtk_widget_set_margin_start(outerBox, PickerWindow.outerMargin)
    gtk_widget_set_margin_end(outerBox, PickerWindow.outerMargin)
    gtk_widget_set_margin_top(outerBox, PickerWindow.outerMargin)
    gtk_widget_set_margin_bottom(outerBox, PickerWindow.outerMargin)

    // Visual-parity pass (see `PickerStyleSheet.swift`): `picker-search`
    // strips `GtkSearchEntry`'s default pill/frame chrome to match macOS's
    // borderless, flush-with-the-header search field (`PickerView
    // .searchField`); `picker-header-row`/`picker-tab-row` each carry a
    // bottom hairline standing in for one of `PickerView`'s three plain
    // `Divider()`s (header/tab-bar/content) — see that view's `body`.
    gtk_widget_add_css_class(searchEntry, "picker-search")
    gtk_widget_add_css_class(chipsBox, "picker-header-row")
    gtk_widget_add_css_class(tabsBox, "picker-tab-row")

    gtk_box_append(outerBox, searchEntry)
    gtk_box_append(outerBox, chipsBox)
    gtk_box_append(outerBox, tabsBox)

    gtk_scrolled_window_set_policy(scrolledWindow, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_widget_set_vexpand(scrolledWindow, 1)
    // Visual-parity pass: clears the stock opaque-white "view" fill so the
    // list area shares the window's own background — see
    // `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(scrolledWindow, "picker-scroll")
    gtk_list_box_set_selection_mode(listBox, GTK_SELECTION_SINGLE)
    // Visual-parity pass: drives `list.picker-list row`'s padding/margin and
    // the macOS-style translucent (non-inverted-text) selection highlight —
    // see `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(listBox, "picker-list")
    gtk_scrolled_window_set_child(scrolledWindow, listBox)
    gtk_box_append(outerBox, scrolledWindow)

    gtk_widget_set_halign(loadingLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(loadingLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(loadingLabel, 1)
    gtk_widget_set_visible(loadingLabel, 0)
    gtk_box_append(outerBox, loadingLabel)

    // T-RT5: same centered/hidden-by-default treatment as `loadingLabel`
    // immediately above — only one of {scrolledWindow, loadingLabel,
    // emptyStateLabel} is ever visible at a time (see
    // `updateContentVisibility(snapshot:)`, `PickerWindow+Reconcile.swift`).
    gtk_label_set_wrap(emptyStateLabel, 1)
    gtk_label_set_justify(emptyStateLabel, GTK_JUSTIFY_CENTER)
    gtk_widget_add_css_class(emptyStateLabel, "dim-label")
    // Visual-parity pass: matches `PickerView.emptyState`'s `.callout` text
    // size (~12pt) — see `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(emptyStateLabel, "picker-empty")
    gtk_widget_set_halign(emptyStateLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(emptyStateLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(emptyStateLabel, 1)
    gtk_widget_set_margin_start(emptyStateLabel, PickerWindow.outerMargin * 3)
    gtk_widget_set_margin_end(emptyStateLabel, PickerWindow.outerMargin * 3)
    gtk_widget_set_visible(emptyStateLabel, 0)
    gtk_box_append(outerBox, emptyStateLabel)

    gtk_label_set_xalign(footerLabel, 0)
    gtk_widget_add_css_class(footerLabel, "dim-label")
    // Visual-parity pass: matches `PickerView.shortcutHintBar`'s
    // `.caption2` size + the `Divider()` above it — see
    // `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(footerLabel, "picker-footer")
    gtk_box_append(outerBox, footerLabel)

    gtk_window_set_child(window, outerBox)

    buildTabs()
    buildChips()
    buildPreviewPopover()
    buildContextMenuPopover()
  }

  /// Linux parity pass (routed follow-up, 2026-09-06): parents the
  /// right-click context menu popover to `listBox` for the window's whole
  /// lifetime — mirrors `buildPreviewPopover()` immediately below, except
  /// this popover's CHILD is built fresh per right-click (its content
  /// depends on which row/kind was clicked), not once here — see
  /// `PickerWindow+ContextMenu.swift`. `autohide` stays at its default
  /// (`TRUE`) — unlike `previewPopover` (explicitly `0`, since that one must
  /// stay open while hovered/scrolled), a context menu SHOULD dismiss on an
  /// outside click or Escape, matching every other GTK/desktop context menu.
  func buildContextMenuPopover() {
    gtk_widget_set_parent(contextMenuPopover, listBox)
  }

  /// The hover-preview popover's content — built once and reused for every
  /// row (see `PickerWindow+Preview.swift`, which only ever mutates this
  /// content's visibility/markup/pixbuf, never rebuilds it).
  func buildPreviewPopover() {
    gtk_widget_set_parent(previewPopover, listBox)
    gtk_popover_set_autohide(previewPopover, 0)

    let previewBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.outerSpacing)
    gtk_widget_set_size_request(previewImage, ThumbnailBounds.previewMaxPixelSize.gtkInt32, -1)
    gtk_box_append(previewBox, previewImage)
    gtk_label_set_wrap(previewLabel, 1)
    gtk_box_append(previewBox, previewLabel)
    gtk_popover_set_child(previewPopover, previewBox)
  }
}
