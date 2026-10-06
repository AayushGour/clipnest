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
      // Visual-parity pass (see `PickerStyleSheet.swift`): `flat` strips
      // GTK's default button chrome (border/background), leaving
      // `picker-tab`'s own caption-size text + secondary-gray active pill
      // (`:checked`) — matches `TabSwitcher`'s `Color.secondary.opacity(0.2)`
      // pill, not an accent color.
      gtk_widget_add_css_class(button, "flat")
      gtk_widget_add_css_class(button, "picker-tab")
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
    buildNewSnippetButton()
  }

  /// Linux parity pass (routed follow-up, 2026-09-06): see
  /// `newSnippetButton`'s doc comment (`PickerWindow.swift`) for why this
  /// exists. Matches macOS `PickerView.tabBar`'s trailing `"New Snippet"`
  /// button exactly: hidden unless the Snippets tab is active (`.history`
  /// is the initial tab — see `buildTabs()` immediately above — so this
  /// starts hidden), no gating beyond that (creating a snippet is always
  /// valid, unlike `ItemRowActions.saveAsSnippet`'s per-kind gate).
  private func buildNewSnippetButton() {
    // An empty, `hexpand`-ing box is the standard GTK4 idiom for a
    // "flexible spacer" inside a `GtkBox` (there is no dedicated `Spacer`
    // widget the way SwiftUI has one) — pushes `newSnippetButton` to the
    // row's trailing edge, matching macOS's `TabSwitcher` + `Spacer()` +
    // trailing button layout (`PickerView.tabBar`).
    let spacer: OpaquePointer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_set_hexpand(spacer, 1)
    gtk_box_append(tabsBox, spacer)

    gtk_widget_add_css_class(newSnippetButton, "flat")
    gtk_widget_set_tooltip_text(newSnippetButton, "New Snippet")
    gtk_widget_set_visible(newSnippetButton, 0)
    gtkConnect(
      newSnippetButton, signal: "clicked", context: self,
      callback: unsafeBitCast(newSnippetButtonClickedTrampoline, to: GCallback.self))
    gtk_box_append(tabsBox, newSnippetButton)
  }

  func handleNewSnippetButtonClicked() {
    MainActor.assumeIsolated {
      viewModel.presentCreateSnippetForm()
    }
  }

  func buildChips() {
    var groupSource: OpaquePointer?
    func makeChip(kind: ItemKind?, iconName: String, tooltip: String) {
      let button: OpaquePointer = gtk_toggle_button_new()
      gtk_button_set_icon_name(button, iconName)
      gtk_widget_set_tooltip_text(button, tooltip)
      // Visual-parity pass: mirrors `ExpandingIconButton`'s icon-only
      // 22pt/5px-radius chip, `:checked` giving the 0.2-opacity active fill
      // `TypeFilterChips` uses — see `PickerStyleSheet.swift`.
      gtk_widget_add_css_class(button, "flat")
      gtk_widget_add_css_class(button, "picker-chip")
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
    // Reached by every tab switch regardless of trigger — a tab button
    // click, or `PickerWindow+Keyboard.swift`'s `Ctrl+1/2/3` (which itself
    // drives this via `gtk_toggle_button_set_active`, firing this same
    // `"toggled"` signal) — so this one place keeps `newSnippetButton`'s
    // visibility correct either way.
    gtk_widget_set_visible(newSnippetButton, tab == .snippets ? 1 : 0)
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

/// `GtkButton::clicked` (`newSnippetButton`) — `void (*)(GtkButton*, gpointer)`.
private let newSnippetButtonClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
      window.handleNewSnippetButtonClicked()
    }
