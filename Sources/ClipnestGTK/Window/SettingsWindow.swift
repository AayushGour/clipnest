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

  /// Whether this machine can actually perform on-device OCR right now
  /// (`OnnxTextRecognizer.isAvailable` — `ClipnestLinuxOCR`'s `dlopen`
  /// check for `libonnxruntime.so.1` plus the PP-OCRv5 models actually
  /// being installed). `ClipnestGTK` sits BELOW `ClipnestLinuxOCR` in the
  /// dependency graph (same constraint `launchAtLoginProvider`/
  /// `reinstallToggleHotkeyFloor` below already document), so this is a
  /// plain `Bool` resolved once at the composition root
  /// (`LinuxAppEnvironment.init`), not a live import. `buildHistoryTab()`
  /// gates the "Recognize text in copied images" toggle and Fast/Accurate
  /// quality picker on this — `clipnest` only `Recommends` `clipnest-ocr`,
  /// so a `--no-install-recommends` install must never show controls that
  /// would silently no-op.
  let isTextRecognitionAvailable: Bool

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

  /// T-OPT3: reads the CURRENT, real uinput auto-paste grant state (see
  /// `UInputPermissionStatus`'s doc comment for why it's two independent
  /// booleans) — called at tab-build time and again every `show()`, never
  /// cached across those calls, so a grant that only took effect after a
  /// re-login is reflected the next time the user opens Settings.
  ///
  /// Injected across the `ClipnestGTK` -> `ClipnestLinuxAppKit` module
  /// boundary, same reasoning as `reinstallToggleHotkeyFloor` above — the
  /// real implementation (`UInputPermissionChecker`, `ClipnestLinuxAppKit`)
  /// does real, side-effect-free `access(2)`/`getgrnam(3)` syscalls this
  /// module cannot reach directly. Deliberately NOT given a default value —
  /// see `reinstallToggleHotkeyFloor`'s doc comment for why a defaulted seam
  /// is a build-time-invisible way to ship a dead feature.
  let uinputPermissionStatusProvider: () -> UInputPermissionStatus

  /// T-OPT3: invokes `pkexec clipnest-grant-input` (see
  /// `GrantInputHelperClient`, `ClipnestLinuxAppKit`) and reports the
  /// outcome via `completion`. `completion` may be called on ANY thread —
  /// `SettingsWindow+Permissions.swift`'s call site hops back to the GTK
  /// thread itself before touching any widget. Also deliberately not
  /// defaulted, same reasoning as `uinputPermissionStatusProvider` above.
  let requestUInputGrant: (_ completion: @escaping @Sendable (UInputGrantOutcome) -> Void) -> Void

  /// T-LXUPD: current installed version text, shown in the General tab
  /// (`UpdateSettingsPresentation.versionLine`) — the Linux analogue of
  /// macOS's `AppUpdater.currentVersion` (`CFBundleShortVersionString`).
  /// This binary ships no bundle/plist to read that from at runtime, so the
  /// composition root (`LinuxAppEnvironment.installedVersion`) resolves it
  /// once and passes it in as a plain value — same reasoning
  /// `isTextRecognitionAvailable` above already documents for a one-shot,
  /// resolved-at-launch fact.
  let installedVersionText: String

  /// T-LXUPD: detects whether Clipnest is managed by apt/a PPA or was
  /// installed from a raw `.deb` — see `LinuxUpdateProvenance`'s doc
  /// comment. Crosses the `ClipnestGTK` -> `ClipnestLinuxAppKit` module
  /// boundary as an injected closure (the real implementation,
  /// `LinuxAppUpdater.detectProvenance()`, does a real `apt-cache policy`
  /// process spawn this module cannot reach directly) — same pattern as
  /// `uinputPermissionStatusProvider` above. Deliberately NOT given a
  /// default value — see `reinstallToggleHotkeyFloor`'s doc comment for why
  /// a defaulted seam is a build-time-invisible way to ship a dead feature.
  let detectUpdateProvenance: () async -> LinuxUpdateProvenance

  /// T-LXUPD: runs the actual checksum-verified download + `pkexec
  /// apt-get install` (`LinuxAppUpdater.performUpdate`, `ClipnestLinuxAppKit`)
  /// — only ever invoked by `SettingsWindow+General.swift` after its own
  /// explicit "Install Update…" confirmation dialog, never automatically.
  /// `onStep` may be called from any thread; the real call site hops back
  /// to the GTK thread itself before touching any widget. Also deliberately
  /// not defaulted, same reasoning as `requestUInputGrant` above.
  let performLinuxAppUpdate:
    (_ onStep: @escaping @Sendable (LinuxUpdateStep) -> Void) async -> LinuxUpdateOutcome

  /// T-LXUPD: the exact apt command shown (selectable, for copy-paste) when
  /// `detectUpdateProvenance` reports `.packageManaged`
  /// (`LinuxAppUpdater.aptUpgradeCommand()`). A plain, precomputed `String`
  /// rather than a closure — unlike the two collaborators above, it never
  /// changes at runtime.
  let aptUpgradeCommand: String

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

  /// Permissions tab (`SettingsWindow+Permissions.swift`, T-OPT3) — every
  /// widget `refreshPermissionsStatus()`/`requestUInputGrantFromUI()` need
  /// to update. All `nil` until `buildPermissionsTab()` runs (during
  /// `init`), same contract as every other tab's widget refs above.
  var permissionsUInputStatusLabel: OpaquePointer?
  var permissionsGroupStatusLabel: OpaquePointer?
  var permissionsReloginNoteLabel: OpaquePointer?
  var permissionsResultLabel: OpaquePointer?
  var permissionsGrantButton: OpaquePointer?

  /// General tab's update section (`SettingsWindow+General.swift`, T-LXUPD)
  /// — every widget `refreshUpdateAvailabilityUI()`/`startInstallUpdate()`
  /// need to update. All `nil` until `buildGeneralTab()` runs (during
  /// `init`), same contract as every other tab's widget refs above.
  var updateVersionLabel: OpaquePointer?
  var updateExplanationLabel: OpaquePointer?
  var updateAptCommandLabel: OpaquePointer?
  var updateInstallButton: OpaquePointer?
  var updateStatusLabel: OpaquePointer?

  public init(
    settings: SettingsStore,
    updateChecker: UpdateChecker,
    clipStore: any ClipStore,
    ocrBackfillViewModel: OCRBackfillViewModel,
    isTextRecognitionAvailable: Bool,
    launchAtLoginProvider: @escaping () -> Bool,
    setLaunchAtLogin: @escaping (Bool) throws -> Void,
    reinstallToggleHotkeyFloor: @escaping (_ accelerator: String) -> Void,
    uinputPermissionStatusProvider: @escaping () -> UInputPermissionStatus,
    requestUInputGrant: @escaping (_ completion: @escaping @Sendable (UInputGrantOutcome) -> Void)
      -> Void,
    installedVersionText: String,
    detectUpdateProvenance: @escaping () async -> LinuxUpdateProvenance,
    performLinuxAppUpdate: @escaping (
      _ onStep: @escaping @Sendable (LinuxUpdateStep) -> Void
    ) async -> LinuxUpdateOutcome,
    aptUpgradeCommand: String
  ) {
    self.settings = settings
    self.updateChecker = updateChecker
    self.clipStore = clipStore
    self.ocrBackfillViewModel = ocrBackfillViewModel
    self.isTextRecognitionAvailable = isTextRecognitionAvailable
    self.launchAtLoginProvider = launchAtLoginProvider
    self.setLaunchAtLogin = setLaunchAtLogin
    self.reinstallToggleHotkeyFloor = reinstallToggleHotkeyFloor
    self.uinputPermissionStatusProvider = uinputPermissionStatusProvider
    self.requestUInputGrant = requestUInputGrant
    self.installedVersionText = installedVersionText
    self.detectUpdateProvenance = detectUpdateProvenance
    self.performLinuxAppUpdate = performLinuxAppUpdate
    self.aptUpgradeCommand = aptUpgradeCommand
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
      buildPermissionsTab()
      startOCRBackfillPolling()
    }
  }

  public func show() {
    // T-OPT3: re-reads the real uinput grant state every time Settings is
    // opened — see `refreshPermissionsStatus()`'s doc comment for why this,
    // rather than a continuous poll, is the right cadence for state that
    // only ever changes at login time or via this same window's own Grant
    // button.
    MainActor.assumeIsolated {
      refreshPermissionsStatus()
      // T-LXUPD: same re-read-every-show cadence as
      // `refreshPermissionsStatus()` above — see
      // `SettingsWindow+General.swift`'s `refreshUpdateAvailabilityUI()`
      // doc comment for why that's the right cadence for this state too.
      refreshUpdateAvailabilityUI()
    }
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
