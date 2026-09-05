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
  static let rowIconPixelSize: Int32 = 24
  static let rowSpacing: Int32 = 8

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

  /// Removes every current child of `listBox` — GTK4 has no bulk
  /// "remove all," only per-child removal, so this loops popping the first
  /// remaining child until none are left (the standard GTK4 idiom for a
  /// full rebuild; see GTK's own migration examples for `gtk_list_box_remove`).
  func clearListBox() {
    while let child = gtk_widget_get_first_child(listBox) {
      gtk_list_box_remove(listBox, child)
    }
  }

  /// Rebuilds `listBox` from `rows` for the History/Pinned tabs.
  func rebuildRows(_ rows: [ClipItem], searchText: String) {
    clearListBox()
    renderedRows = rows
    renderedSnippets = []
    for item in rows {
      let content = ClipItemRowContent(item: item, searchText: searchText)
      gtk_list_box_append(listBox, makeClipItemRowWidget(content))
    }
  }

  /// Rebuilds `listBox` from `snippets` for the Snippets tab.
  func rebuildSnippets(_ snippets: [Snippet], searchText: String) {
    clearListBox()
    renderedSnippets = snippets
    renderedRows = []
    for snippet in snippets {
      let content = SnippetRowContent(snippet: snippet, searchText: searchText)
      gtk_list_box_append(listBox, makeSnippetRowWidget(content))
    }
  }

  private func makeClipItemRowWidget(_ content: ClipItemRowContent) -> OpaquePointer {
    let row: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, PickerWindow.rowSpacing)
    let icon: OpaquePointer = gtk_image_new_from_icon_name(content.iconName)
    gtk_image_set_pixel_size(icon, PickerWindow.rowIconPixelSize)
    gtk_box_append(row, icon)

    let label: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_markup(label, content.markupText)
    gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END)
    gtk_label_set_xalign(label, 0)
    gtk_widget_set_hexpand(label, 1)
    gtk_box_append(row, label)

    if content.isPinned {
      let pinIcon: OpaquePointer = gtk_image_new_from_icon_name("view-pin")
      gtk_box_append(row, pinIcon)
    }
    if content.hasRecognizedText {
      let ocrIcon: OpaquePointer = gtk_image_new_from_icon_name("edit-find")
      gtk_widget_set_tooltip_text(ocrIcon, "Recognized text available")
      gtk_box_append(row, ocrIcon)
    }
    if let sourceAppLabel = content.sourceAppLabel {
      let appLabel: OpaquePointer = gtk_label_new(sourceAppLabel)
      gtk_widget_add_css_class(appLabel, "dim-label")
      gtk_box_append(row, appLabel)
    }
    return row
  }

  private func makeSnippetRowWidget(_ content: SnippetRowContent) -> OpaquePointer {
    let row: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, PickerWindow.chipSpacing)
    let titleLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_markup(titleLabel, content.markupTitle)
    gtk_label_set_xalign(titleLabel, 0)
    gtk_box_append(row, titleLabel)

    let bodyLabel: OpaquePointer = gtk_label_new(nil)
    gtk_label_set_markup(bodyLabel, content.markupBody)
    gtk_label_set_ellipsize(bodyLabel, PANGO_ELLIPSIZE_END)
    gtk_label_set_xalign(bodyLabel, 0)
    gtk_widget_add_css_class(bodyLabel, "dim-label")
    gtk_box_append(row, bodyLabel)
    return row
  }

  /// Selects `listBox`'s row at `index`, or clears selection when `index`
  /// is `nil` — used by `PickerWindow+Polling.swift` to keep GTK's own
  /// selection in sync with `PickerViewModel.selectedItemID`/
  /// `.selectedSnippetID` after a poll detects `.selection` changed
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
