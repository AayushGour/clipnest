// SettingsWindow.swift
//
// P7-D (Linux port, GTK4 view layer): the GTK4 counterpart of macOS's
// `SettingsView` — four tabs (General/History/Apps/Shortcuts) in a
// `GtkNotebook`, backed directly by `SettingsStore` (`ClipnestViewModels`).
//
// Mostly no poll loop, unlike `PickerWindow`: `SettingsStore` on Linux is a
// plain class with no notification mechanism (see that type's `#if
// canImport(Darwin)` gate on `@Observable` — off Apple platforms it's
// nothing more than stored properties with a `didSet` that persists to
// `KeyValueStore`), and every mutation to it in this whole subsystem
// originates from THIS window's own control signals — nothing else ever
// changes it out from under the UI while Settings is open, so there is no
// external-change case to poll for there.
//
// P10-A: ONE exception — `OCRBackfillViewModel` (History tab's "Recognize
// Text in Existing Images" row). Unlike `SettingsStore`, its state changes
// asynchronously from a background `Task` the user started (see that
// type's doc comment), and — also unlike `PickerViewModel` on this
// platform — it has no `ClipnestObservation`/`ObservableObject` conformance
// to subscribe to (it stays a plain class off Apple; adding that
// conformance is a `ClipnestViewModels` change out of this task's owned-
// files scope). `SettingsWindow+History.swift`'s `pollOCRBackfillTick()`
// is therefore a small, self-contained `g_timeout_add_full` poll (the same
// mechanism `PickerWindow` itself used before its own push-based
// migration), scoped to just that row's five widgets.
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
import ClipnestCore
import ClipnestViewModels

// `@unchecked Sendable`: see `PickerWindow.swift`'s identical annotation
// and doc comment — the same "sending 'self'" diagnostic, the same
// single-GTK-thread proof, for the same reason.
public final class SettingsWindow: @unchecked Sendable {
  let settings: SettingsStore
  let updateChecker: UpdateChecker
  let clipStore: any ClipStore
  let ocrBackfillViewModel: OCRBackfillViewModel

  /// P10-A: `AutostartDesktopFile` (`ClipnestLinuxAppKit`) is unreachable
  /// from this module — see this file's top doc comment's link note, and
  /// `LinuxAppEnvironment.init`'s own doc comment at its call site. Two
  /// plain closures cross that module boundary instead, the same shape
  /// `ClipboardMonitor.captureEnabledProvider`/`excludedBundleIDsProvider`
  /// already use for an identical cross-module-boundary need.
  let launchAtLoginProvider: () -> Bool
  let setLaunchAtLogin: (Bool) throws -> Void

  /// T-OPT2: re-installs the GSettings custom-keybinding floor after the
  /// user rebinds the global toggle hotkey in Settings > Shortcuts.
  ///
  /// Injected rather than called directly because the floor lives in
  /// `ClipnestLinuxAppKit` (`ToggleHotkeyFloorBinding`), which this module
  /// cannot import — `ClipnestGTK` sits BELOW it in the dependency graph,
  /// the same constraint `launchAtLoginProvider`/`setLaunchAtLogin` above
  /// already work around.
  ///
  /// Deliberately NOT given a default value. `PickerViewModel
  /// .presentSnippetEditor` was declared with a `{ _ in }` default, Linux
  /// never injected it, and the result was that snippet creation silently
  /// did nothing on Linux for the entire port — the failure mode was
  /// invisible precisely because the default made the call site compile.
  /// A required parameter turns the same mistake into a build error.
  let reinstallToggleHotkeyFloor: (_ accelerator: String) -> Void

  let window: OpaquePointer
  let notebook: OpaquePointer

  /// The Apps tab's user-exclusions list + its "add" entry field — held so
  /// `SettingsWindow+Apps.swift` can rebuild the list after each add/remove
  /// and clear the entry after a successful add. `nil` until
  /// `buildAppsTab()` runs (during `init`).
  var excludedAppsListBox: OpaquePointer?
  var addExcludedAppEntry: OpaquePointer?

  /// General tab (`SettingsWindow+General.swift`) — held so a failed
  /// `setLaunchAtLogin` can revert the checkbox to the real filesystem
  /// state and show an inline error, mirroring macOS's `GeneralSettingsView`
  /// exactly. `nil` until `buildGeneralTab()` runs (during `init`).
  var launchAtLoginCheckButton: OpaquePointer?
  var launchAtLoginErrorLabel: OpaquePointer?

  /// History tab (`SettingsWindow+History.swift`) — the "Clear All
  /// History…" inline error label, and every widget the OCR backfill row
  /// needs to show/hide/update on `pollOCRBackfillTick()`. All `nil` until
  /// `buildHistoryTab()` runs (during `init`).
  var clearHistoryErrorLabel: OpaquePointer?
  var ocrProgressLabel: OpaquePointer?
  var ocrProgressBar: OpaquePointer?
  var ocrCancelButton: OpaquePointer?
  var ocrSummaryLabel: OpaquePointer?
  var ocrPendingLabel: OpaquePointer?
  var ocrRunButton: OpaquePointer?
  /// The `g_timeout_add_full` source polling `ocrBackfillViewModel` — see
  /// this file's top doc comment. Started once in `init` and never stopped:
  /// this window is a permanent, app-lifetime singleton (never torn down),
  /// mirroring `UpdateChecker`'s own steady-state timer.
  var ocrPollSourceID: UInt32?

  public init(
    settings: SettingsStore,
    updateChecker: UpdateChecker,
    clipStore: any ClipStore,
    ocrBackfillViewModel: OCRBackfillViewModel,
    launchAtLoginProvider: @escaping () -> Bool,
    setLaunchAtLogin: @escaping (Bool) throws -> Void,
    reinstallToggleHotkeyFloor: @escaping (_ accelerator: String) -> Void
  ) {
    self.settings = settings
    self.updateChecker = updateChecker
    self.clipStore = clipStore
    self.ocrBackfillViewModel = ocrBackfillViewModel
    self.launchAtLoginProvider = launchAtLoginProvider
    self.setLaunchAtLogin = setLaunchAtLogin
    self.reinstallToggleHotkeyFloor = reinstallToggleHotkeyFloor
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
      startOCRBackfillPolling()
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
