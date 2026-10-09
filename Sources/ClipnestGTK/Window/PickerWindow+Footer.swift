// PickerWindow+Footer.swift
//
// The picker's footer row, mirroring macOS `PickerView.shortcutHintBar`:
// tab-aware shortcut hints on the left (word-wrapped so a long
// hint string neither widens the window past `defaultWidth` nor hides
// shortcuts behind an ellipsis) and a muted
// `v<version>` button on the right with an accent dot while
// `viewModel.isUpdateAvailable`. Clicking the version opens Settings
// (General: "Check for Updates Now" / "Install Update…") via the same
// `openSettingsFromPicker()` Ctrl+, uses — Linux has no picker-side update
// confirmation flow.

import CGtk4
import ClipnestViewModels

extension PickerWindow {
  static let footerVersionTooltipDefault = "Open Settings to check for updates"

  static func footerVersionText(_ version: String) -> String {
    "v\(version)"
  }

  static func footerVersionTooltip(isUpdateAvailable: Bool, latestVersion: String?) -> String {
    guard isUpdateAvailable, let latestVersion else { return footerVersionTooltipDefault }
    return "Update to v\(latestVersion) available — open Settings"
  }

  func buildFooter(in outerBox: OpaquePointer) {
    gtk_label_set_xalign(footerLabel, 0)
    gtk_widget_set_hexpand(footerLabel, 1)
    // Wrap (word boundaries) instead of one long line: the Linux vocabulary
    // is ~25% longer than macOS's and an ellipsis would hide the tab/settings
    // shortcuts. Wrapping also drops the label's minimum width to one word,
    // so the hint string can no longer widen the window past `defaultWidth`
    // (it used to: 762 px measured on X11).
    gtk_label_set_wrap(footerLabel, 1)
    gtk_label_set_wrap_mode(footerLabel, PANGO_WRAP_WORD)
    gtk_label_set_width_chars(footerLabel, 0)
    gtk_widget_add_css_class(footerLabel, "dim-label")
    gtk_widget_add_css_class(footerLabel, "picker-footer-hints")

    gtk_widget_add_css_class(footerUpdateDot, "picker-footer-update-dot")
    gtk_widget_set_visible(footerUpdateDot, 0)
    gtk_widget_add_css_class(footerVersionButton, "flat")
    gtk_widget_add_css_class(footerVersionButton, "picker-footer-version")
    gtkConnect(
      footerVersionButton, signal: "clicked", context: self,
      callback: unsafeBitCast(footerVersionClickedTrampoline, to: GCallback.self))

    gtk_widget_add_css_class(footerBox, "picker-footer")
    gtk_box_append(footerBox, footerLabel)
    gtk_box_append(footerBox, footerUpdateDot)
    gtk_box_append(footerBox, footerVersionButton)
    gtk_box_append(outerBox, footerBox)
    updateFooterVersion()
  }

  /// Idempotent; called from every reconcile (the update flag is not part of
  /// the poll snapshot).
  func updateFooterVersion() {
    let (version, available, latest) = MainActor.assumeIsolated {
      (viewModel.appVersion, viewModel.isUpdateAvailable, viewModel.latestVersion)
    }
    gtk_button_set_label(footerVersionButton, PickerWindow.footerVersionText(version))
    gtk_widget_set_visible(footerUpdateDot, available ? 1 : 0)
    gtk_widget_set_tooltip_text(
      footerVersionButton,
      PickerWindow.footerVersionTooltip(isUpdateAvailable: available, latestVersion: latest))
  }

  func handleFooterVersionClicked() {
    MainActor.assumeIsolated { viewModel.openSettingsFromPicker() }
  }
}

/// `GtkButton::clicked` (`footerVersionButton`).
private let footerVersionClickedTrampoline:
  @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) ->
    Void = { _, data in
      guard let window = unretainedContext(data, as: PickerWindow.self) else { return }
      window.handleFooterVersionClicked()
    }
