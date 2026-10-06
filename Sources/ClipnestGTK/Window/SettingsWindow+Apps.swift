// SettingsWindow+Apps.swift
//
// P7-D (Linux port, GTK4 view layer): the Apps settings tab — the GTK
// counterpart of macOS's `AppsSettingsView`. Built-in excluded apps
// (`PrivacyFilter.builtInExcludedBundleIDs`) are shown locked; user
// exclusions are added by typing an identifier (a bundle ID on macOS — on
// Linux, whatever identifier the platform layer's focused-app lookup
// reports, e.g. a `.desktop` file ID or WM class; `SettingsStore` itself is
// identifier-format-agnostic, it only stores/compares strings) and
// removable. See `SettingsWindow+General.swift`'s doc comment for the
// `@MainActor`/`MainActor.assumeIsolated` split this file follows too.
import CGtk4
import ClipnestCore
import ClipnestViewModels

extension SettingsWindow {
  static let appsTabRowSpacing: Int32 = 4

  @MainActor
  func buildAppsTab() {
    let box = appendTab(title: "Apps")

    let lockedLabel: OpaquePointer = gtk_label_new("Always excluded")
    gtk_label_set_xalign(lockedLabel, 0)
    gtk_widget_add_css_class(lockedLabel, "dim-label")
    gtk_box_append(box, lockedLabel)

    let lockedList: OpaquePointer = gtk_list_box_new()
    gtk_list_box_set_selection_mode(lockedList, GTK_SELECTION_NONE)
    for bundleID in PrivacyFilter.builtInExcludedBundleIDs.sorted() {
      let row: OpaquePointer = gtk_box_new(
        GTK_ORIENTATION_HORIZONTAL, SettingsWindow.appsTabRowSpacing)
      let label: OpaquePointer = gtk_label_new(bundleID)
      gtk_label_set_xalign(label, 0)
      gtk_widget_set_hexpand(label, 1)
      gtk_box_append(row, label)
      let lockIcon: OpaquePointer = gtk_image_new_from_icon_name("changes-prevent")
      gtk_box_append(row, lockIcon)
      gtk_list_box_append(lockedList, row)
    }
    gtk_box_append(box, lockedList)

    let excludedLabel: OpaquePointer = gtk_label_new("Excluded apps")
    gtk_label_set_xalign(excludedLabel, 0)
    gtk_widget_add_css_class(excludedLabel, "dim-label")
    gtk_box_append(box, excludedLabel)

    let excludedList: OpaquePointer = gtk_list_box_new()
    gtk_list_box_set_selection_mode(excludedList, GTK_SELECTION_NONE)
    excludedAppsListBox = excludedList
    gtk_box_append(box, excludedList)

    let addRow: OpaquePointer = gtk_box_new(
      GTK_ORIENTATION_HORIZONTAL, SettingsWindow.appsTabRowSpacing)
    let entry: OpaquePointer = gtk_entry_new()
    gtk_widget_set_hexpand(entry, 1)
    addExcludedAppEntry = entry
    gtk_box_append(addRow, entry)
    addButton(to: addRow, label: "Add") { [weak self] in
      MainActor.assumeIsolated {
        self?.addExcludedAppFromEntry()
      }
    }
    gtk_box_append(box, addRow)

    refreshExcludedAppsList()
  }

  @MainActor
  private func addExcludedAppFromEntry() {
    guard let addExcludedAppEntry else { return }
    let text = String(cString: gtk_editable_get_text(addExcludedAppEntry))
    settings.addExcludedApp(bundleID: text)
    gtk_editable_set_text(addExcludedAppEntry, "")
    refreshExcludedAppsList()
  }

  @MainActor
  private func removeExcludedApp(bundleID: String) {
    settings.removeExcludedApp(bundleID: bundleID)
    refreshExcludedAppsList()
  }

  /// Rebuilds the user-exclusions list from `settings.userExcludedBundleIDs`
  /// — called after every add/remove, since `SettingsStore` has no change
  /// notification to poll for (see `SettingsWindow.swift`'s top doc
  /// comment) and every mutation here already originates from this same
  /// window.
  @MainActor
  private func refreshExcludedAppsList() {
    guard let excludedAppsListBox else { return }
    while let child = gtk_widget_get_first_child(excludedAppsListBox) {
      gtk_list_box_remove(excludedAppsListBox, child)
    }
    for bundleID in settings.userExcludedBundleIDs {
      let row: OpaquePointer = gtk_box_new(
        GTK_ORIENTATION_HORIZONTAL, SettingsWindow.appsTabRowSpacing)
      let label: OpaquePointer = gtk_label_new(bundleID)
      gtk_label_set_xalign(label, 0)
      gtk_widget_set_hexpand(label, 1)
      gtk_box_append(row, label)
      addButton(to: row, label: "Remove") { [weak self] in
        MainActor.assumeIsolated {
          self?.removeExcludedApp(bundleID: bundleID)
        }
      }
      gtk_list_box_append(excludedAppsListBox, row)
    }
  }
}
