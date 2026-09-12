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
//             ├─ previewLabel               (hidden for .image — see
//             │                              PickerWindow+Preview.swift)
//             ├─ previewFileSizeLabel        (.file only)
//             ├─ previewFilePathLabel        (.file only)
//             ├─ previewOCRSeparator         (.image w/ recognized text only)
//             ├─ previewOCRHeaderLabel       ("Recognized Text", ditto)
//             └─ previewOCRTextLabel         (ditto)
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

    // Routed bug report ("make it honest" — Phase 2): same centered/
    // hidden-by-default/wrapped treatment as `emptyStateLabel` immediately
    // above — see `PickerWindow.showClipboardOnlyNoticeThenDismiss()`.
    gtk_label_set_wrap(clipboardOnlyNoticeLabel, 1)
    gtk_label_set_justify(clipboardOnlyNoticeLabel, GTK_JUSTIFY_CENTER)
    gtk_widget_add_css_class(clipboardOnlyNoticeLabel, "picker-empty")
    gtk_widget_set_halign(clipboardOnlyNoticeLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(clipboardOnlyNoticeLabel, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(clipboardOnlyNoticeLabel, 1)
    gtk_widget_set_margin_start(clipboardOnlyNoticeLabel, PickerWindow.outerMargin * 3)
    gtk_widget_set_margin_end(clipboardOnlyNoticeLabel, PickerWindow.outerMargin * 3)
    gtk_widget_set_visible(clipboardOnlyNoticeLabel, 0)
    gtk_box_append(outerBox, clipboardOnlyNoticeLabel)

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

  /// Approximates macOS `ItemPreview.textMaxWidth`/`ocrTextMaxHeight`'s 380pt
  /// text column (`ItemPreview.swift`) — GTK labels wrap by character count,
  /// not points, so this is a deliberate approximation, not a pixel match.
  /// Applied to every wrapped preview text label (`previewLabel`,
  /// `previewOCRTextLabel`, `previewFilePathLabel`) so the popover's text
  /// column stays a consistent, readable width instead of growing to fit
  /// whatever the longest line happens to be.
  static let previewTextMaxWidthChars: Int32 = 46
  /// Mirrors macOS `FilePreview`'s `.lineLimit(4)` on the file path line.
  static let previewFilePathMaxLines: Int32 = 4

  /// The hover-preview popover's content — built once and reused for every
  /// row (see `PickerWindow+Preview.swift`, which only ever mutates this
  /// content's visibility/markup/pixbuf, never rebuilds it). Layout mirrors
  /// macOS `ItemPreview.content`: an `.image` shows the thumbnail plus an
  /// optional recognized-text section below it (T-OCR2 parity); `.file`
  /// shows a filename headline plus size/path metadata rows; plain
  /// text/richText/link shows just the wrapped text — see
  /// `PickerWindow+Preview.swift`'s `updatePreviewPopover(targetID:)` for
  /// which of these is actually visible for a given item.
  func buildPreviewPopover() {
    gtk_widget_set_parent(previewPopover, listBox)
    gtk_popover_set_autohide(previewPopover, 0)

    let previewBox: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.outerSpacing)
    gtk_widget_set_size_request(previewImage, ThumbnailBounds.previewMaxPixelSize.gtkInt32, -1)
    gtk_box_append(previewBox, previewImage)

    gtk_label_set_wrap(previewLabel, 1)
    gtk_label_set_xalign(previewLabel, 0)
    gtk_label_set_max_width_chars(previewLabel, PickerWindow.previewTextMaxWidthChars)
    gtk_box_append(previewBox, previewLabel)

    // `.file` metadata — secondary-styled (`dim-label`, matching
    // `emptyStateLabel`'s own use of that stock GTK class elsewhere in this
    // file) rows below the filename headline (`previewLabel`) above.
    gtk_widget_add_css_class(previewFileSizeLabel, "dim-label")
    gtk_widget_add_css_class(previewFileSizeLabel, "picker-row-meta")
    gtk_label_set_xalign(previewFileSizeLabel, 0)
    gtk_box_append(previewBox, previewFileSizeLabel)

    gtk_widget_add_css_class(previewFilePathLabel, "dim-label")
    gtk_widget_add_css_class(previewFilePathLabel, "picker-row-meta")
    gtk_label_set_xalign(previewFilePathLabel, 0)
    gtk_label_set_wrap(previewFilePathLabel, 1)
    gtk_label_set_max_width_chars(previewFilePathLabel, PickerWindow.previewTextMaxWidthChars)
    gtk_label_set_lines(previewFilePathLabel, PickerWindow.previewFilePathMaxLines)
    gtk_label_set_ellipsize(previewFilePathLabel, PANGO_ELLIPSIZE_MIDDLE)
    gtk_box_append(previewBox, previewFilePathLabel)

    // Recognized-text section (T-OCR2 parity) — separator + caption + the
    // same wrap/width treatment as `previewLabel` above.
    gtk_box_append(previewBox, previewOCRSeparator)
    gtk_widget_add_css_class(previewOCRHeaderLabel, "dim-label")
    gtk_widget_add_css_class(previewOCRHeaderLabel, "picker-row-meta")
    gtk_label_set_xalign(previewOCRHeaderLabel, 0)
    gtk_box_append(previewBox, previewOCRHeaderLabel)

    gtk_label_set_wrap(previewOCRTextLabel, 1)
    gtk_label_set_xalign(previewOCRTextLabel, 0)
    gtk_label_set_max_width_chars(previewOCRTextLabel, PickerWindow.previewTextMaxWidthChars)
    gtk_box_append(previewBox, previewOCRTextLabel)

    gtk_popover_set_child(previewPopover, previewBox)
  }
}
