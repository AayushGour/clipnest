// PickerWindow+Rows.swift
//
// P7-D (Linux port, GTK4 view layer): renders `PickerViewModel.rows`/
// `.snippetRows` into `listBox`, and reports scroll-driven paging + row
// selection/activation back to the view model. Every row's CONTENT is
// computed by the pure, unit-tested `ClipItemRowContent`/`SnippetRowContent`
// (`Support/`) — this file only ever does "build a widget from an already-
// decided content value" / "read GTK's own row index," never its own
// highlighting/icon-name logic.
//
// Row identity: `renderedRows`/`renderedSnippets` (declared on `PickerWindow`)
// are rebuilt in the SAME order `listBox`'s children are appended, so
// `gtk_list_box_row_get_index(row)` — GTK's own, always-correct row
// position — indexes directly into whichever array is live for the active
// tab. No separate per-row id map is needed.
import CGtk4
import ClipnestCore
import ClipnestViewModels

extension PickerWindow {
  // Visual-parity pass (see `PickerStyleSheet.swift`): matches `ItemRow`'s
  // leading icon slot (`.frame(width: 18)`, thumbnails rendered at 20×20 —
  // `ItemRow.swift`) and its outer `HStack(spacing: 10)`.
  static let rowIconPixelSize: Int32 = 20
  static let rowSpacing: Int32 = 10
  /// Small badge icons (pin, OCR) — matches the compact, secondary-sized
  /// badges `ItemRow` overlays on its thumbnail/rows rather than GTK's
  /// default (larger) icon size.
  static let rowBadgeIconPixelSize: Int32 = 14

  /// Defense-in-depth bound for `clearListBox()`'s loop — see that
  /// method's doc comment for the exact infinite-loop bug this backstops.
  /// `PickerViewModel.pageSize` (the largest `rows`/`snippetRows` window
  /// this app ever renders) is 75; comfortably larger than any real row
  /// count without being so large a genuine future bug would still hang
  /// the process for a meaningful amount of time before tripping it.
  static let clearListBoxIterationCap = 1000

  func connectRowSignals() {
    gtkConnect(
      listBox, signal: "row-selected", context: self,
      callback: unsafeBitCast(rowSelectedTrampoline, to: GCallback.self))
    gtkConnect(
      listBox, signal: "row-activated", context: self,
      callback: unsafeBitCast(rowActivatedTrampoline, to: GCallback.self))

    let adjustment = gtk_scrolled_window_get_vadjustment(scrolledWindow)
    gtkConnect(
      adjustment, signal: "value-changed", context: self,
      callback: unsafeBitCast(adjustmentChangedTrampoline, to: GCallback.self))
  }

  /// Removes every current ROW child of `listBox` — GTK4 has no bulk
  /// "remove all," only per-child removal, so this loops popping the first
  /// remaining row until none are left (the standard GTK4 idiom for a full
  /// rebuild; see GTK's own migration examples for `gtk_list_box_remove`).
  ///
  /// P10-D (found via this task's own runtime verification, not a
  /// pre-existing test): `previewPopover` is a genuine, permanent
  /// widget-tree child of `listBox` — `PickerWindow+Layout.swift` parents
  /// it there via `gtk_widget_set_parent(previewPopover, listBox)` exactly
  /// once, for the window's whole lifetime (see that file's tree diagram —
  /// "parented to listBox, NOT part of the tree above"). It is NOT a
  /// `GtkListBoxRow`, so `gtk_list_box_remove` correctly refuses it every
  /// time it's offered ("Tried to remove non-child"). The original loop
  /// here (`while let child = gtk_widget_get_first_child(listBox) { remove
  /// }`, with no stop condition beyond "no children left") didn't know to
  /// stop there: real rows are always positioned before the popover in
  /// `listBox`'s child order (confirmed empirically — GTK's own row
  /// management inserts new rows ahead of a manually-parented, non-row
  /// widget), so the loop worked correctly right up until the moment it
  /// needed to clear the LAST real row — at which point
  /// `gtk_widget_get_first_child` started returning the popover forever,
  /// `gtk_list_box_remove` refused it forever, and this became an
  /// unconditional infinite loop: reproduced by closing and reopening the
  /// picker with exactly one existing history item, which drives
  /// `updateRows`'s rebuild fallback (`appendedSuffixStart` correctly
  /// returns `nil` for an equal-count "rebuild" — see that function's doc
  /// comment) to clear exactly one row down to zero. Observed firsthand
  /// while diagnosing this: a fully hung GTK main thread and a multi-
  /// gigabyte, tens-of-millions-of-lines log file — hence `iterationCap`
  /// below as a defense-in-depth backstop against any OTHER unexpected
  /// non-removable child appearing in the future; this exact bug class (an
  /// unconditional `while` loop against live GTK container state) has no
  /// other guard against turning into exactly that again.
  /// Linux parity pass (routed follow-up, 2026-09-06): `contextMenuPopover`
  /// added to the `child != previewPopover` guard below — it is now a
  /// SECOND permanent, non-row `listBox` child (`gtk_widget_set_parent
  /// (contextMenuPopover, listBox)`, `PickerWindow+Layout.swift`'s
  /// `buildContextMenuPopover()`), and this loop's own doc comment already
  /// documents exactly the infinite-loop failure mode a missed non-row
  /// child produces here (reproduced firsthand earlier this session for
  /// `previewPopover`) — `gtk_list_box_remove` would refuse it forever the
  /// same way once every real row is gone, hanging the GTK main thread.
  func clearListBox() {
    var iterations = 0
    while let child = gtk_widget_get_first_child(listBox), child != previewPopover,
      child != contextMenuPopover
    {
      gtk_list_box_remove(listBox, child)
      iterations += 1
      guard iterations <= Self.clearListBoxIterationCap else { break }
    }
  }

  /// Updates `listBox` for the History/Pinned tabs from `rows` — the entry
  /// point `PickerWindow+Reconcile.swift`'s `reconcile(aspects:snapshot:)`
  /// calls whenever `.rows` changed. `canAppend` (computed by the caller,
  /// which already knows whether the active tab or search text also
  /// changed since the last reconcile — see that method's doc comment)
  /// gates whether an incremental append is even on the table; ON TOP of
  /// that, `appendedSuffixStart` (below) checks whether `rows` ACTUALLY has
  /// the one shape safe to append (pure growth off the end — pagination's
  /// `loadMoreIfNeeded()`) rather than tearing down and rebuilding every
  /// row already on screen (P10-D: the other half of the cost an audit
  /// flagged alongside the 33ms poll loop this task replaces — see
  /// `appendedSuffixStart`'s doc comment for exactly which row-list changes
  /// this optimizes and which still fall back to a full rebuild).
  func updateRows(_ rows: [ClipItem], searchText: String, canAppend: Bool) {
    if canAppend, let start = PickerWindow.appendedSuffixStart(old: renderedRows, new: rows) {
      appendClipItemRows(Array(rows[start...]), searchText: searchText)
      renderedRows = rows
    } else {
      rebuildRows(rows, searchText: searchText)
    }
  }

  /// Updates `listBox` for the Snippets tab from `snippets` — see
  /// `updateRows(_:searchText:canAppend:)`'s doc comment; identical shape,
  /// the Snippets tab's own array.
  func updateSnippetRows(_ snippets: [Snippet], searchText: String, canAppend: Bool) {
    if canAppend, let start = PickerWindow.appendedSuffixStart(old: renderedSnippets, new: snippets)
    {
      appendSnippetRowsSuffix(Array(snippets[start...]), searchText: searchText)
      renderedSnippets = snippets
    } else {
      rebuildSnippets(snippets, searchText: searchText)
    }
  }

  /// Rebuilds `listBox` from `rows` for the History/Pinned tabs.
  func rebuildRows(_ rows: [ClipItem], searchText: String) {
    clearListBox()
    renderedRows = rows
    renderedSnippets = []
    appendClipItemRows(rows, searchText: searchText)
  }

  /// Rebuilds `listBox` from `snippets` for the Snippets tab.
  func rebuildSnippets(_ snippets: [Snippet], searchText: String) {
    clearListBox()
    renderedSnippets = snippets
    renderedRows = []
    appendSnippetRowsSuffix(snippets, searchText: searchText)
  }

  private func appendClipItemRows(_ items: [ClipItem], searchText: String) {
    for item in items {
      let content = ClipItemRowContent(item: item, searchText: searchText)
      gtk_list_box_append(listBox, makeClipItemRowWidget(content, item: item))
    }
  }

  private func appendSnippetRowsSuffix(_ snippets: [Snippet], searchText: String) {
    for snippet in snippets {
      let content = SnippetRowContent(snippet: snippet, searchText: searchText)
      gtk_list_box_append(listBox, makeSnippetRowWidget(content, snippet: snippet))
    }
  }

  /// Returns the number of leading elements `new` shares with `old`
  /// unchanged, if and only if `new` is exactly `old` plus zero or more
  /// elements appended after it — the one row-list-change shape safe to
  /// render as an incremental append instead of a full teardown+rebuild
  /// (every widget `old` already has on screen stays exactly as it is;
  /// only the new tail needs building). Every other shape — search results
  /// replacing the list, a new capture PREPENDING an item
  /// (`PickerViewModel.handleNewCapture()`'s `.softReconcile` requery — the
  /// exact case this task's runtime verification exercises: a capture
  /// landing while the picker is open), a pin/unpin re-sort, or a row's own
  /// content changing in place — returns `nil`, and the caller
  /// (`updateRows`/`updateSnippetRows` above) falls back to the existing
  /// full rebuild, unchanged from before this task. General keyed diffing
  /// (matching rows by `id` across arbitrary insertions/removals/reorders/
  /// in-place content changes, reusing widgets for every row that didn't
  /// actually change) would close the rest of this gap, but is a much
  /// larger undertaking with real correctness edges of its own (stale
  /// widget reuse, selection/scroll-position preservation across a
  /// reorder) — deliberately NOT attempted here; left for a future task.
  static func appendedSuffixStart<T: Equatable>(old: [T], new: [T]) -> Int? {
    guard new.count > old.count, Array(new.prefix(old.count)) == old else { return nil }
    return old.count
  }

  /// - Parameter item: the raw model backing `content` — needed only for
  ///   `ItemRowActions.buttons(for:)`'s gating/labels and to capture into
  ///   each button's click closure (see `PickerWindow+RowActions.swift`).
  ///   `content` stays the single source for everything else (icon,
  ///   markup, pin/OCR badges, source-app label) — this does not duplicate
  ///   any of `ClipItemRowContent`'s own logic.
  private func makeClipItemRowWidget(_ content: ClipItemRowContent, item: ClipItem) -> OpaquePointer
  {
    let row: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.rowSpacing)
    let icon: OpaquePointer = gtk_image_new_from_icon_name(content.iconName)
    gtk_image_set_pixel_size(icon, PickerWindow.rowIconPixelSize)
    gtk_box_append(row, icon)

    let label: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_markup(label, content.markupText)
    gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END)
    gtk_label_set_xalign(label, 0)
    gtk_widget_set_hexpand(label, 1)
    // Visual-parity pass: matches `ItemRow`'s unstyled (system `.body`,
    // 13pt) preview-text `Text` — see `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(label, "picker-row-title")
    gtk_box_append(row, label)

    // Linux parity pass (routed follow-up, 2026-09-06): the pin STATE badge
    // that used to live here is gone — `ItemRow`'s own history (see that
    // file's doc comment) already made this exact call on macOS: "the pin
    // button's icon alone communicates pinned state ... there's no separate
    // badge anymore." The interactive pin/unpin button appended below (via
    // `rowActionButtons`) is now the only pinned indicator, mirroring that.
    if content.hasRecognizedText {
      let ocrIcon: OpaquePointer = gtk_image_new_from_icon_name("edit-find")
      gtk_image_set_pixel_size(ocrIcon, PickerWindow.rowBadgeIconPixelSize)
      gtk_widget_set_tooltip_text(ocrIcon, "Recognized text available")
      gtk_box_append(row, ocrIcon)
    }
    if let sourceAppLabel = content.sourceAppLabel {
      let appLabel: OpaquePointer = gtk_label_new(sourceAppLabel)
      gtk_widget_add_css_class(appLabel, "dim-label")
      // Visual-parity pass: matches `ItemRow`'s secondary `.caption` (~10pt)
      // timestamp line's size — see `PickerStyleSheet.swift`.
      gtk_widget_add_css_class(appLabel, "picker-row-meta")
      gtk_box_append(row, appLabel)
    }

    let actions: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.chipSpacing)
    gtk_widget_add_css_class(actions, "picker-row-actions")
    for entry in ItemRowActions.buttons(for: item) {
      gtk_box_append(actions, makeItemRowActionButton(entry, item: item))
    }
    gtk_box_append(row, actions)
    return row
  }

  /// - Parameter snippet: the raw model backing `content` — needed only for
  ///   `SnippetRowActions.buttons()`'s click closures. See
  ///   `makeClipItemRowWidget(_:item:)`'s matching doc comment.
  private func makeSnippetRowWidget(_ content: SnippetRowContent, snippet: Snippet) -> OpaquePointer
  {
    let outerRow: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.rowSpacing)
    let textColumn: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.chipSpacing)
    gtk_widget_set_hexpand(textColumn, 1)
    let titleLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_markup(titleLabel, content.markupTitle)
    gtk_label_set_xalign(titleLabel, 0)
    // Visual-parity pass: matches `SnippetRow`'s unstyled title `Text` —
    // see `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(titleLabel, "picker-row-title")
    gtk_box_append(textColumn, titleLabel)

    let bodyLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_markup(bodyLabel, content.markupBody)
    gtk_label_set_ellipsize(bodyLabel, PANGO_ELLIPSIZE_END)
    gtk_label_set_xalign(bodyLabel, 0)
    gtk_widget_add_css_class(bodyLabel, "dim-label")
    // Visual-parity pass: matches `SnippetRow`'s `.caption` (~10pt) body
    // preview size — see `PickerStyleSheet.swift`.
    gtk_widget_add_css_class(bodyLabel, "picker-row-meta")
    gtk_box_append(textColumn, bodyLabel)
    gtk_box_append(outerRow, textColumn)

    let actions: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.chipSpacing)
    gtk_widget_add_css_class(actions, "picker-row-actions")
    for entry in SnippetRowActions.buttons() {
      gtk_box_append(actions, makeSnippetRowActionButton(entry, snippet: snippet))
    }
    gtk_box_append(outerRow, actions)
    return outerRow
  }

  /// Icon name for one `ItemRowAction`'s always-visible button — freedesktop
  /// icon-naming-spec names where one exists (`list-add`, `edit-delete` —
  /// same spec `content.iconName`/`"edit-find"` already draw from), `"view
  /// -pin"` reused as-is from the badge this replaces (see
  /// `makeClipItemRowWidget`'s doc comment) since it has no standard-spec
  /// equivalent but is already an established, verified-rendering choice in
  /// this codebase. `.copyRecognizedText` is never asked for here —
  /// `ItemRowActions.buttons(for:)` never includes it.
  private static func iconName(for action: ItemRowAction) -> String {
    switch action {
    case .togglePin: return "view-pin"
    case .saveAsSnippet: return "list-add"
    case .copyRecognizedText: return "edit-find"
    case .delete: return "edit-delete"
    }
  }

  private static func iconName(for action: SnippetRowAction) -> String {
    switch action {
    case .edit: return "document-edit"
    case .delete: return "edit-delete"
    }
  }

  /// Builds one of a History/Pinned row's always-visible trailing icon
  /// buttons — `entry`'s label becomes the button's tooltip (GTK has no
  /// macOS-style hover-reveal label; the tooltip is the closest equivalent
  /// discoverability mechanism). Clicking dispatches through the single
  /// shared `performItemRowAction(_:for:)` (`PickerWindow+RowActions.swift`)
  /// — the exact same dispatch the row's right-click context menu entry for
  /// this action uses (`PickerWindow+ContextMenu.swift`), so the action
  /// itself is wired to `PickerViewModel` in exactly one place.
  private func makeItemRowActionButton(_ entry: ItemRowActionEntry, item: ClipItem) -> OpaquePointer
  {
    let button: OpaquePointer = gtk_button_new_from_icon_name(Self.iconName(for: entry.action))
    gtk_widget_add_css_class(button, "flat")
    if entry.isDestructive {
      gtk_widget_add_css_class(button, "destructive-action")
    }
    gtk_widget_set_tooltip_text(button, entry.label)
    gtkConnect(
      button, signal: "clicked",
      context: ClosureContext<Void> { [weak self] in
        self?.performItemRowAction(entry.action, for: item)
      },
      callback: unsafeBitCast(rowActionButtonClickedTrampoline, to: GCallback.self))
    return button
  }

  /// Snippets-tab counterpart of `makeItemRowActionButton(_:item:)` — see
  /// its doc comment.
  private func makeSnippetRowActionButton(_ entry: SnippetRowActionEntry, snippet: Snippet)
    -> OpaquePointer
  {
    let button: OpaquePointer = gtk_button_new_from_icon_name(Self.iconName(for: entry.action))
    gtk_widget_add_css_class(button, "flat")
    if entry.isDestructive {
      gtk_widget_add_css_class(button, "destructive-action")
    }
    gtk_widget_set_tooltip_text(button, entry.label)
    gtkConnect(
      button, signal: "clicked",
      context: ClosureContext<Void> { [weak self] in
        self?.performSnippetRowAction(entry.action, for: snippet)
      },
      callback: unsafeBitCast(rowActionButtonClickedTrampoline, to: GCallback.self))
    return button
  }

  /// Selects `listBox`'s row at `index`, or clears selection when `index`
  /// is `nil` — used by `PickerWindow+Reconcile.swift` to keep GTK's own
  /// selection in sync with `PickerViewModel.selectedItemID`/
  /// `.selectedSnippetID` after a reconcile detects `.selection` changed
  /// (including a change GTK itself didn't originate, e.g. arrow-key
  /// navigation, which mutates `viewModel` directly — see
  /// `PickerWindow+Keyboard.swift`).
  func syncListBoxSelection(toIndex index: Int?) {
    guard let index else {
      gtk_list_box_unselect_all(listBox)
      return
    }
    guard let row = gtk_list_box_get_row_at_index(listBox, index.gtkInt32) else { return }
    gtk_list_box_select_row(listBox, row)
  }

  func handleRowSelected(row: OpaquePointer?) {
    guard let row else { return }
    let index = Int(gtk_list_box_row_get_index(row))
    MainActor.assumeIsolated {
      switch viewModel.activeTab {
      case .history, .pinned:
        guard renderedRows.indices.contains(index) else { return }
        viewModel.selectedItemID = renderedRows[index].id
      case .snippets:
        guard renderedSnippets.indices.contains(index) else { return }
        viewModel.selectedSnippetID = renderedSnippets[index].id
      }
    }
  }

  func handleRowActivated() {
    markPasteAttemptPending()
    MainActor.assumeIsolated {
      viewModel.selectHighlighted()
    }
  }

  func handleAdjustmentChanged(_ adjustment: OpaquePointer?) {
    guard let adjustment else { return }
    let shouldLoad = ScrollPaging.shouldLoadMore(
      value: gtk_adjustment_get_value(adjustment),
      pageSize: gtk_adjustment_get_page_size(adjustment),
      upper: gtk_adjustment_get_upper(adjustment))
    guard shouldLoad else { return }
    MainActor.assumeIsolated {
      viewModel.loadMoreIfNeeded()
    }
  }
}

/// `GtkButton::clicked` for one of a row's always-visible action buttons —
/// `void (*)(GtkButton*, gpointer)`. Shared by every button
/// `makeItemRowActionButton(_:item:)`/`makeSnippetRowActionButton(_:snippet:)`
/// builds; the actual per-button behavior lives entirely in the
/// `ClosureContext<Void>` each connection supplies (see `SettingsWindow
/// +Controls.swift`'s `buttonClickedTrampoline` for the identical shape —
/// not reused directly since it is file-private there, per this module's
/// established per-file-trampoline convention; see `Interop
/// /GTKCallbackTrampoline.swift`'s top doc comment).
private let rowActionButtonClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let context = unretainedContext(data, as: ClosureContext<Void>.self) else { return }
      context.perform(())
    }

/// `GtkListBox::row-selected` — `void (*)(GtkListBox*, GtkListBoxRow*, gpointer)`.
private let rowSelectedTrampoline:
  @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { _, row, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handleRowSelected(row: row)
  }

/// `GtkListBox::row-activated` — `void (*)(GtkListBox*, GtkListBoxRow*, gpointer)`.
private let rowActivatedTrampoline:
  @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { _, _, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handleRowActivated()
  }

/// `GtkAdjustment::value-changed` — `void (*)(GtkAdjustment*, gpointer)`.
private let adjustmentChangedTrampoline:
  @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?
  ) -> Void = { adjustment, data in
    guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
    window.handleAdjustmentChanged(adjustment)
  }
