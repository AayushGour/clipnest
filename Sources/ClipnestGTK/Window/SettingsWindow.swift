// SettingsWindow.swift
//
// P7-D (Linux port, GTK4 view layer): the GTK4 counterpart of macOS's
// `SettingsView` — four tabs (General/History/Apps/Shortcuts) in a
// `GtkNotebook`, backed directly by `SettingsStore` (`ClipnestViewModels`).
//
// No poll loop here, unlike `PickerWindow`: `SettingsStore` on Linux is a
// plain class with no notification mechanism (see that type's `#if
// canImport(Darwin)` gate on `@Observable` — off Apple platforms it's
// nothing more than stored properties with a `didSet` that persists to
// `KeyValueStore`), and every mutation to it in this whole subsystem
// originates from THIS window's own control signals — nothing else ever
// changes it out from under the UI while Settings is open, so there is no
// external-change case to poll for (contrast `PickerWindow`, whose
// `PickerViewModel` state changes asynchronously via the store query
// pipeline even while the picker is simply sitting open).
//
// Same actor-isolation note as `PickerWindow.swift` applies here too:
// `SettingsStore`'s `@MainActor` annotation (on the class declaration
// itself) is UNCONDITIONAL — only its `@Observable` conformance is gated
// `#if canImport(Darwin)`, not its actor isolation — so every read/write of
// `settings` below goes through `MainActor.assumeIsolated { ... }`, exactly
// like `PickerWindow`'s `viewModel` accesses, and for the identical reason:
// this window's `init`/`show()`/control-signal closures all run on the
// single GTK thread, which is the same thread the whole process's
// main-actor work runs on (see `PickerWindow.swift`'s top doc comment for
// the full argument).
import CGtk4
import ClipnestViewModels

// `@unchecked Sendable`: see `PickerWindow.swift`'s identical annotation
// and doc comment — the same "sending 'self'" diagnostic, the same
// single-GTK-thread proof, for the same reason.
public final class SettingsWindow: @unchecked Sendable {
  let settings: SettingsStore

  let window: OpaquePointer
  let notebook: OpaquePointer

  /// The Apps tab's user-exclusions list + its "add" entry field — held so
  /// `SettingsWindow+Apps.swift` can rebuild the list after each add/remove
  /// and clear the entry after a successful add. `nil` until
  /// `buildAppsTab()` runs (during `init`).
  var excludedAppsListBox: OpaquePointer?
  var addExcludedAppEntry: OpaquePointer?

  public init(settings: SettingsStore) {
    self.settings = settings
    window = gtk_window_new()
    notebook = gtk_notebook_new()

    gtk_window_set_title(window, "Clipnest Settings")
    gtk_window_set_default_size(window, SettingsWindow.defaultWidth, SettingsWindow.defaultHeight)
    // Clicking the OS close button hides rather than destroys the window,
    // so a later `show()` still operates on a live `GtkWindow` — this
    // window is built once and reused for the app's whole lifetime,
    // mirroring `PickerWindow`'s own lifetime note.
    gtk_window_set_hide_on_close(window, 1)
    gtk_window_set_child(window, notebook)

    MainActor.assumeIsolated {
      buildGeneralTab()
      buildHistoryTab()
      buildAppsTab()
      buildShortcutsTab()
    }
  }

  public func show() {
    gtk_widget_set_visible(window, 1)
    gtk_window_present(window)
  }

  static let defaultWidth: Int32 = 480
  static let defaultHeight: Int32 = 420
  static let tabMargin: Int32 = 12
  static let controlSpacing: Int32 = 8

  /// Builds one notebook tab's outer vertical box (margins + spacing
  /// applied consistently) and appends it to `notebook` with `title` as
  /// its label — every `build*Tab()` method starts by calling this,
  /// keeping the per-tab boilerplate in one place.
  func appendTab(title: String) -> OpaquePointer {
    let box: OpaquePointer = gtk_box_new(GTK_ORIENTATION_VERTICAL, SettingsWindow.controlSpacing)
    gtk_widget_set_margin_start(box, SettingsWindow.tabMargin)
    gtk_widget_set_margin_end(box, SettingsWindow.tabMargin)
    gtk_widget_set_margin_top(box, SettingsWindow.tabMargin)
    gtk_widget_set_margin_bottom(box, SettingsWindow.tabMargin)
    let tabLabel: OpaquePointer = gtk_label_new(title)
    _ = gtk_notebook_append_page(notebook, box, tabLabel)
    return box
  }
}
