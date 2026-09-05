// PickerWindow+Chips.swift
//
// P7-D (Linux port, GTK4 view layer): the tab switcher (History/Pinned/
// Snippets) and type-filter chips (All/Text/Rich Text/Link/Image/File) —
// the GTK counterparts of macOS's `TabSwitcher`/`TypeFilterChips`. Both are
// a row of radio-grouped `GtkToggleButton`s (`gtk_toggle_button_set_group`
// gives GTK3's removed `GtkRadioButton` behavior in GTK4: exactly one
// active at a time).
//
// Each button's identity (which tab / which kind it represents) travels
// through its own retained context object (`TabButtonContext`/
// `ChipButtonContext`), per `Interop/GTKCallbackTrampoline.swift`'s
// documented pattern — there is no Swift closure capture anywhere in this
// file.
import CGtk4
import ClipnestCore
import ClipnestViewModels

/// Retained per tab button (see `Interop/GTKCallbackTrampoline.swift`).
final class TabButtonContext {
  let window: PickerWindow
  let tab: PickerTab
  init(window: PickerWindow, tab: PickerTab) {
    self.window = window
    self.tab = tab
  }
}

/// Retained per type-filter chip. `kind == nil` is the "All" chip.
final class ChipButtonContext {
  let window: PickerWindow
  let kind: ItemKind?
  init(window: PickerWindow, kind: ItemKind?) {
    self.window = window
    self.kind = kind
  }
}

extension PickerWindow {
  func buildTabs() {
    var groupSource: OpaquePointer?
    for tab in PickerTab.allCases {
      let button: OpaquePointer = gtk_toggle_button_new_with_label(tab.title)
      if let groupSource {
        gtk_toggle_button_set_group(button, groupSource)
      } else {
        groupSource = button
      }
      gtk_toggle_button_set_active(button, tab == .history ? 1 : 0)
      gtkConnect(
        button, signal: "toggled",
        context: TabButtonContext(window: self, tab: tab),
        callback: unsafeBitCast(tabToggledTrampoline, to: GCallback.self))
      gtk_box_append(tabsBox, button)
      tabButtons.append(button)
    }
  }

  func buildChips() {
    var groupSource: OpaquePointer?
    func makeChip(kind: ItemKind?, iconName: String, tooltip: String) {
      let button: OpaquePointer = gtk_toggle_button_new()
      gtk_button_set_icon_name(button, iconName)
      gtk_widget_set_tooltip_text(button, tooltip)
      if let groupSource {
        gtk_toggle_button_set_group(button, groupSource)
      } else {
        groupSource = button
      }
      gtk_toggle_button_set_active(button, kind == nil ? 1 : 0)
      gtkConnect(
        button, signal: "toggled",
        context: ChipButtonContext(window: self, kind: kind),
        callback: unsafeBitCast(chipToggledTrampoline, to: GCallback.self))
      gtk_box_append(chipsBox, button)
      chipButtons.append(button)
    }

    makeChip(kind: nil, iconName: "edit-find", tooltip: "All")
    for kind in ItemKind.allCases {
      makeChip(kind: kind, iconName: kind.gtkIconName, tooltip: ItemKindChipLabel.label(for: kind))
    }
  }

  func handleTabToggled(tab: PickerTab, isActive: Bool) {
    guard isActive else { return }
    MainActor.assumeIsolated {
      viewModel.activeTab = tab
    }
  }

  func handleChipToggled(kind: ItemKind?, isActive: Bool) {
    guard isActive else { return }
    MainActor.assumeIsolated {
      viewModel.query.kindFilter = kind
    }
  }
}

/// `GtkToggleButton::toggled` — `void (*)(GtkToggleButton*, gpointer)`.
private let tabToggledTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void =
    { button, data in
      guard let button, let context = unretainedContext(data, as: TabButtonContext.self) else {
        return
      }
      context.window.handleTabToggled(
        tab: context.tab, isActive: gtk_toggle_button_get_active(button) != 0)
    }

private let chipToggledTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void =
    { button, data in
      guard let button, let context = unretainedContext(data, as: ChipButtonContext.self) else {
        return
      }
      context.window.handleChipToggled(
        kind: context.kind, isActive: gtk_toggle_button_get_active(button) != 0)
    }
