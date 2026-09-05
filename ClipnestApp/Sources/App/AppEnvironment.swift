// AppEnvironment.swift
//
// Clipnest's app composition root: builds and owns the single, shared graph
// of `ClipnestCore` services + the picker UI, and hands them out by
// injection. Nothing here is a global/singleton — `AppDelegate` builds
// exactly one `AppEnvironment` on launch and every consumer (the picker,
// later Settings) receives its dependencies from this one owned graph.
//
// The one wiring rule this exists to enforce: `clipStore` and
// `clipboardMonitor` MUST share the *same* `BlobStore` instance. Both types
// have their own default `BlobStore` constructor parameter for convenience
// in isolated unit tests, but relying on those defaults here would silently
// give each its own `BlobStore` pointed at the same directory — two
// independent instances that happen to agree on paths today, but are one
// refactor away from drifting apart. Constructing exactly one `BlobStore`
// and passing it to both explicitly removes that risk entirely.
//
// Persistence (plan task T40, project-context.md decision D6): the
// production graph is wired to `SwiftDataClipStore`/`SwiftDataSnippetStore`
// — real on-disk persistence via SwiftData, confined behind the same
// `ClipStore`/`SnippetStore` protocols `InMemoryClipStore`/
// `InMemorySnippetStore` implement (those remain the canonical stores for
// `ClipnestCoreTests`, unchanged). `PickerViewModel`/`ClipboardMonitor` both
// depend on `any ClipStore`, so this swap is invisible to them.
//
// Plan task T16: also wires the real paste engine. `frontmostAppTracker`
// is recorded here, in `showPicker()`, right before the panel is shown —
// the one choke point both trigger paths (the global hotkey and the menu
// bar's "Open Clipnest") already share via `AppDelegate.showPicker()` — so
// neither trigger path needs its own record() call. `paster`'s
// `isAccessibilityGranted` is fed the real `PermissionsManager.isGranted`
// (itself a thin wrapper over `AXIsProcessTrusted()`), so the picker's
// select action performs a real synthesized ⌘V when Accessibility is
// granted and falls back to clipboard-only when it isn't.
//
// T23 fix round: owns the one `SnippetEditorWindow` instance too, wiring
// `PickerViewModel.presentSnippetEditor` directly to it — see that window
// type's doc comment for why the snippet editor needed its own key-capable
// `NSWindow` instead of a `.sheet()` on the non-activating `PickerPanel`.
//
// Task 12 (item preview): also owns the one `ItemPreviewController`,
// wiring `PickerViewModel.updatePreview` to its `update(...)` — the
// preview panel it manages must never take key focus (same non-activating
// requirement `PickerPanel` itself has, D11), so `panel.frame` is passed
// through purely as a coarse screen-space anchor rect, never as a focus
// relationship. `panel.onDidHide` also explicitly hides the preview
// alongside `viewModel.didHide()`, so it can't outlive the picker itself.

import AppKit
import ClipnestCore
// P5 (Phase 3, Linux port): `SettingsStore`/`OCRBackfillViewModel`/
// `PickerViewModel`/`UpdateChecker` moved to `ClipnestViewModels`.
import ClipnestViewModels
import Foundation
import os

@MainActor
final class AppEnvironment {
  private static let logger = Logger(subsystem: ClipnestLog.subsystem, category: "AppEnvironment")

  let blobStore: BlobStore
  let clipStore: SwiftDataClipStore
  let snippetStore: SwiftDataSnippetStore
  /// T-UX1: `@MainActor` state + orchestration for the Settings "Recognize
  /// Text in Existing Images" backfill — wraps an `OCRBackfillCoordinator`
  /// (see this initializer's `visionTextRecognizer` local) built to share
  /// `blobStore`/`clipStore` and the same `VisionTextRecognizer` instance
  /// `clipboardMonitor` uses, so a manual backfill and at-capture
  /// recognition inherit the exact same `recognitionQueue` serialization
  /// (see `VisionTextRecognizer`'s doc comment / T-HANG1). Owned here, not
  /// by `HistorySettingsView`, matching every other cross-cutting service
  /// in this file (e.g. `updateChecker`).
  let ocrBackfillViewModel: OCRBackfillViewModel
  let privacyFilter: PrivacyFilter
  let settingsStore: SettingsStore
  let pasteboardReader: PasteboardReader
  let clipboardMonitor: ClipboardMonitor
  let paster: Paster
  let frontmostAppTracker: FrontmostAppTracker
  let pickerViewModel: PickerViewModel
  let pickerPanel: PickerPanel
  let snippetEditorWindow: SnippetEditorWindow
  let snippetExpander: SnippetExpander
  let itemPreviewController: ItemPreviewController

  /// Approved feature: background 24h update-availability check — see
  /// `UpdateChecker`'s doc comment. Owned here (not by `PickerViewModel`)
  /// because `GeneralSettingsView` also needs it directly, to call
  /// `settingChanged(enabled:)` when the user flips the Settings toggle.
  let updateChecker: UpdateChecker

  /// Live Accessibility trust state, polled (macOS posts no notification for
  /// a TCC change). Owned here because two very different consumers need the
  /// same signal: the Permissions settings tab renders it, and
  /// `HotkeyManager` must reinstall its `NSEvent` monitors the moment the
  /// grant lands — a global key monitor installed while untrusted stays dead
  /// forever otherwise.
  let accessibilityWatcher: AccessibilityPermissionWatcher

  /// T-PF1 (D2 fix): the in-flight debounced `enforceRetention` call
  /// scheduled by `scheduleRetentionEnforcement()`, if any — see that
  /// method's doc comment. `nil` when no capture-triggered retention pass
  /// is currently pending or running.
  private var pendingRetentionTask: Task<Void, Never>?

  /// How long `scheduleRetentionEnforcement()` waits after the LAST capture
  /// in a burst before actually running `enforceRetention` — long enough to
  /// coalesce a realistic rapid multi-copy burst (e.g. selecting and
  /// copying several items in quick succession, or a script/automation
  /// pasting a sequence of items), short enough that retention still runs
  /// promptly once things settle. Not user-configurable — a purely internal
  /// coalescing window, so it lives here as a named constant rather than a
  /// bare literal at the call site.
  private static let retentionDebounceInterval: Duration = .milliseconds(750)

  /// - Throws: whatever `SwiftDataClipStore`/`SwiftDataSnippetStore`'s
  ///   production `ModelContainer` construction throws (typed
  ///   `ClipStoreError`/`SnippetStoreError.ioFailure`) — e.g. the on-disk
  ///   store file can't be created/opened. There's no safe in-app fallback
  ///   from "persistence didn't come up," so this is surfaced to the caller
  ///   (`AppDelegate`) rather than silently degrading to a store the user
  ///   didn't ask for.
  ///
  /// T-PF1 (D1 launch-latency fix): `async` — previously this was a plain
  /// synchronous `init() throws`, called directly from
  /// `AppDelegate.applicationDidFinishLaunching`, which meant NOTHING in
  /// the app (menu bar icon, run loop) could proceed until it returned.
  /// Two things made that slow: `ModelContainer` construction is blocking
  /// disk I/O (opening/creating the SQLite-backed store, including
  /// `ModelContainerRecovery`'s corrupt-store move-aside retry), and each
  /// store's one-time `normalizedText` backfill (`SwiftDataClipStore
  /// .prepare()`/`SwiftDataSnippetStore.prepare()`) used to run inline in
  /// this same synchronous `init`, an unindexed full-table scan. Both now
  /// run inside `Task.detached`, which hops them onto a background thread
  /// (detached, so they do NOT inherit this initializer's `@MainActor`
  /// isolation) — and the two stores' setups run concurrently with each
  /// other via `async let`, so launch is bounded by the slower of the two,
  /// not their sum. `AppDelegate` now calls this via `try await
  /// AppEnvironment()` from inside its own `Task`, so
  /// `applicationDidFinishLaunching` itself returns immediately.
  init() async throws {
    // One shared BlobStore instance — see the file's doc comment.
    //
    // T-PF8: `BlobStore.defaultBaseDirectory()` (and, transitively,
    // `SwiftDataClipStore`/`SwiftDataSnippetStore.makeProductionContainer()`
    // below, which resolve their on-disk store file the same way) honors the
    // `CLIPNEST_TEST_DATA_ROOT` override — see that method's doc comment.
    // This line is otherwise unchanged production code: with the variable
    // unset (every real launch), this resolves to the exact same
    // `~/Library/Application Support/Clipnest` it always has. The override
    // exists so `ClipnestAppTests` (a *hosted* unit-test target — see
    // `ClipnestApp/project.yml`'s `TEST_HOST`, which genuinely launches this
    // very `init` inside the real app binary under `xcodebuild test`) never
    // opens/migrates/writes the user's real clipboard database and blobs.
    let blobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory())
    let privacyFilter = PrivacyFilter()
    let settingsStore = SettingsStore()
    let pasteboardReader = PasteboardReader()

    async let clipStoreSetup: SwiftDataClipStore = Task.detached(priority: .userInitiated) {
      let container = try SwiftDataClipStore.makeProductionContainer()
      let store = SwiftDataClipStore(modelContainer: container, blobStore: blobStore)
      await store.prepare()
      return store
    }.value
    async let snippetStoreSetup: SwiftDataSnippetStore = Task.detached(priority: .userInitiated) {
      let container = try SwiftDataSnippetStore.makeProductionContainer()
      let store = SwiftDataSnippetStore(modelContainer: container)
      await store.prepare()
      return store
    }.value
    let (clipStore, snippetStore) = try await (clipStoreSetup, snippetStoreSetup)

    self.blobStore = blobStore
    self.privacyFilter = privacyFilter
    self.settingsStore = settingsStore
    self.pasteboardReader = pasteboardReader
    self.clipStore = clipStore
    self.snippetStore = snippetStore

    // T-OCR2/T-UX1: one shared `VisionTextRecognizer` instance for both the
    // at-capture-time path (`clipboardMonitor` below) and the Settings
    // backfill (`ocrBackfillViewModel`) — a plain, stateless struct (no
    // per-instance state to share), but hoisted into one `let` rather than
    // two separate literals so the sharing is explicit at the call site,
    // not just an accident of `recognitionQueue` happening to be `static`.
    // See `VisionTextRecognizer`'s doc comment for why serialization
    // matters here (T-HANG1).
    let visionTextRecognizer = VisionTextRecognizer()
    self.ocrBackfillViewModel = OCRBackfillViewModel(
      coordinator: OCRBackfillCoordinator(
        store: clipStore, blobStore: blobStore, recognizer: visionTextRecognizer))

    // T9 (snippet keyword expansion): the concrete AX-backed
    // `SelectedTextAccessing` (`AXSelectedTextAccessor`) and the universal
    // clipboard fallback (`ClipboardSelectionReplacer`) are app-side, so they
    // must be passed explicitly here — `SnippetExpander`'s initializer has no
    // defaults for them because `ClipnestCore` can't reference app-only types.
    // The replacer's capture-suppression closures are wired to the monitor
    // below (once it exists). See `SnippetExpander`'s doc comment.
    let clipboardReplacer = ClipboardSelectionReplacer()
    self.snippetExpander = SnippetExpander(
      snippetStore: snippetStore,
      selectedText: AXSelectedTextAccessor(),
      clipboardReplacer: clipboardReplacer)

    self.clipboardMonitor = ClipboardMonitor(
      store: clipStore,
      privacyFilter: privacyFilter,
      reader: pasteboardReader,
      blobStore: blobStore,
      excludedBundleIDsProvider: {
        MainActor.assumeIsolated { Set(settingsStore.userExcludedBundleIDs) }
      },
      captureEnabledProvider: {
        MainActor.assumeIsolated { settingsStore.isCaptureEnabled }
      },
      // T-OCR2: on-device OCR at capture time runs ONLY here, inside the
      // real capture path — never at idle-scan or on a background sweep,
      // by construction (there is no other call site that invokes
      // `scheduleTextRecognition`). `ocrBackfillViewModel` above is the
      // ONE other place recognition ever runs (a user-triggered backfill,
      // T-UX1) — see this initializer's `visionTextRecognizer` local for
      // why both share the exact same instance.
      textRecognizer: visionTextRecognizer,
      textRecognitionEnabledProvider: {
        MainActor.assumeIsolated { settingsStore.isTextRecognitionEnabled }
      },
      // T-OCR8: same live-read shape as the enabled provider above — no
      // `ClipboardMonitor`/`VisionTextRecognizer` recreation on a
      // Fast<->Accurate change in Settings.
      textRecognitionQualityProvider: {
        MainActor.assumeIsolated { settingsStore.textRecognitionQuality }
      }
    )

    // T16: real paste engine — see this file's doc comment. Feeds the
    // SILENT `PermissionsManager.isGranted`, never the prompting variant.
    // Pasting is a hot path (every picker selection); asking it to prompt
    // meant macOS's "Clipnest would like to control this computer" dialog
    // reappeared on every paste made while untrusted. Discovering and fixing
    // the permission is the Permissions settings tab's job now, plus the
    // single first-run nudge in `requestAccessibilityOnceIfNeeded()`.
    let paster = Paster(
      isAccessibilityGranted: { PermissionsManager.isGranted }
    )
    self.paster = paster
    let frontmostAppTracker = FrontmostAppTracker()
    self.frontmostAppTracker = frontmostAppTracker

    let viewModel = PickerViewModel(
      clipStore: clipStore,
      snippetStore: snippetStore,
      blobStore: blobStore,
      paster: paster,
      frontmostAppTracker: frontmostAppTracker
    )
    self.pickerViewModel = viewModel

    let panel = PickerPanel {
      PickerView(viewModel: viewModel)
    }
    self.pickerPanel = panel

    let snippetEditorWindow = SnippetEditorWindow()
    self.snippetEditorWindow = snippetEditorWindow

    // Task 12 (item preview): owns the one preview-surface controller —
    // see `ItemPreviewController`'s doc comment for why this presents via a
    // non-key child `NSPanel` rather than `NSPopover`/`.popover`.
    let itemPreviewController = ItemPreviewController()
    self.itemPreviewController = itemPreviewController

    // Polling is started in `registerHotkey()`, not here — construction
    // must stay side-effect-free so tests can build an environment without
    // a background task running.
    self.accessibilityWatcher = AccessibilityPermissionWatcher()

    // Set after `panel`/`clipboardMonitor`/`snippetEditorWindow` exist to
    // break the construction-order cycle: the panel's own SwiftUI content
    // needs a way to dismiss the panel that hosts it, but the panel doesn't
    // exist yet while that content is being built. See
    // `PickerViewModel.dismiss`'s doc comment.
    viewModel.dismiss = { [weak panel] in panel?.hide() }
    // Self-update (approved feature): the version label in
    // `PickerView.shortcutHintBar` and the update it triggers on click —
    // see `AppUpdater`'s doc comment for why this stays network-free in-app
    // (shells out to the public curl updater via Terminal instead).
    viewModel.appVersion = AppUpdater.currentVersion
    viewModel.requestAppUpdate = { AppUpdater.runUpdate() }

    // Approved feature: background 24h update-availability check — see
    // `UpdateChecker`'s doc comment. Purely informational (a badge next to
    // the version label); the click-to-update flow above is unchanged.
    // `start(settings:)` is NOT called here — construction stays side-
    // effect-free (see this file's doc comment) — it's called from
    // `startUpdateChecking()`, invoked by `AppDelegate.
    // applicationDidFinishLaunching` alongside `startCapture()`/
    // `registerHotkey()`.
    let updateChecker = UpdateChecker()
    self.updateChecker = updateChecker
    // P5 (Phase 3, Linux port): `UpdateChecker` lives in `ClipnestViewModels`
    // now and can't reference `AppUpdater` (App-layer, macOS-only) directly
    // — see `UpdateChecker.installedVersion`'s doc comment.
    updateChecker.installedVersion = { AppUpdater.currentVersion }
    updateChecker.onStateChanged = { [weak viewModel] available, latest in
      viewModel?.isUpdateAvailable = available
      viewModel?.latestVersion = latest
    }

    panel.onWillShow = { [weak viewModel] in viewModel?.willShow() }
    panel.onDidHide = { [weak viewModel, weak itemPreviewController] in
      viewModel?.didHide()
      // Belt-and-suspenders alongside `didHide()` clearing
      // `previewTargetID` (which `PickerView`'s own `.onChange` also routes
      // to `itemPreviewController.hide()` via `viewModel.updatePreview`):
      // explicitly hides the preview panel here too, so it can never be
      // left showing after the picker itself hides regardless of SwiftUI
      // update timing.
      itemPreviewController?.hide()
    }
    panel.onCommandDelete = { [weak viewModel] in viewModel?.deleteHighlighted() }
    // T-SET5: ⌘, — see `PickerPanel.onCommandComma`'s doc comment for why
    // this has to be wired at the AppKit layer (via `PickerPanel`) rather
    // than through `PickerView`'s SwiftUI `.onKeyPress`, same shape as
    // `onCommandDelete` immediately above.
    panel.onCommandComma = { [weak viewModel] in viewModel?.openSettingsFromPicker() }

    // Task 12 (item preview): drives the non-key preview panel from
    // `previewTargetID` changes — see `PickerView`'s top doc comment for
    // the `.onChange` → `viewModel.updatePreview` → here → `panel.frame`
    // used as the coarse anchor. `panel.frame` (not per-row rects) is an
    // acceptable first-pass anchor per the task brief — the preview sits
    // beside the whole picker, Maccy-style.
    viewModel.updatePreview = { [weak panel, weak itemPreviewController, weak viewModel] item in
      itemPreviewController?.update(
        item: item,
        blobStore: blobStore,
        besideAnchor: panel?.frame,
        onPreviewHover: { hovering in viewModel?.previewHoverChanged(hovering) }
      )
    }

    // T23 fix round: shows/hides the snippet editor. `onSave` decides
    // create vs. update based on the `mode` this exact `show(...)` call was
    // given — `SnippetEditorWindow` itself has no opinion on `SnippetStore`.
    // `pickerPanel: panel` lets the editor lay itself out as a side-by-side
    // pair with the picker instead of screen-centered — this may reposition
    // `panel`'s frame (never its size) to make room, so the two windows
    // always end up with distinct left edges and, whenever they can fit the
    // screen, zero overlap — see
    // `SnippetEditorWindow.positionRelativeToPicker(_:)`/
    // `WindowPlacement.pairLayout`.
    // `onClose` fires once the editor closes for any reason (Save, Cancel,
    // red button, ⌘W — see that type's doc comment) and re-keys `panel` +
    // refocuses its search field, so the user lands back in a usable picker
    // rather than a picker that's visible but no longer receiving input.
    viewModel.presentSnippetEditor = {
      [weak snippetEditorWindow, weak viewModel, weak panel] mode in
      guard let snippetEditorWindow, let viewModel else { return }
      snippetEditorWindow.show(
        mode: mode,
        pickerPanel: panel,
        onSave: { title, body, keyword in
          switch mode {
          case .create, .createFromClip:
            viewModel.createSnippet(title: title, body: body, keyword: keyword)
          case .edit(let snippet):
            viewModel.updateSnippet(snippet.id, title: title, body: body, keyword: keyword)
          }
        },
        onClose: { [weak panel, weak viewModel] in
          guard let panel, panel.isVisible else { return }
          panel.makeKey()
          viewModel?.refocusSearchField()
        }
      )
    }

    // Fix round 1, bug #1: tell the running monitor to ignore the
    // changeCount produced by the picker's own copy-on-select write, so it
    // doesn't get recaptured as a new external copy on the next poll. See
    // `PickerViewModel.suppressOwnPasteboardWrite`'s and
    // `ClipboardMonitor.ignore(changeCount:)`'s doc comments.
    let monitor = clipboardMonitor
    viewModel.suppressOwnPasteboardWrite = { [weak monitor] changeCount in
      monitor?.ignore(changeCount: changeCount)
    }

    // T50/T51 (DB-virtualization): the picker no longer polls `ClipStore`
    // on a timer — instead, the one shared `ClipboardMonitor` this
    // environment already owns pushes a live update straight into the
    // picker on every real capture, via the new `onCapture` hook. This is
    // the one choke point both live (this) and self-write-suppressed
    // (above) pasteboard observations already share. See
    // `PickerViewModel.handleNewCapture()`'s doc comment for why this is a
    // single bounded page-0 requery, not a full-table refetch.
    monitor.onCapture = { [weak self, weak viewModel] _ in
      viewModel?.handleNewCapture()
      // T-PF1 (D2 fix): was an unconditional `Task { ... enforceRetention
      // ... }` fired on EVERY capture — a rapid burst of copies used to run
      // one full retention pass per capture. `scheduleRetentionEnforcement`
      // debounces this into (at most) one pass per burst.
      self?.scheduleRetentionEnforcement()
    }

    // Snippet-expansion clipboard fallback (`ClipboardSelectionReplacer`):
    // pause capture while it borrows the clipboard for the synthesized
    // copy/paste, then ignore the restore's change and resume — so the
    // transient copy/paste (the selection and the pasted body) never lands in
    // history and the restored (original) clipboard isn't recaptured.
    clipboardReplacer.beginSuppression = { [weak monitor] in monitor?.pause() }
    clipboardReplacer.endSuppression = { [weak monitor] in
      monitor?.ignore(changeCount: NSPasteboard.general.changeCount)
      monitor?.resume()
    }
  }

  /// Starts continuous clipboard capture on a real timer
  /// (`ClipboardMonitor.defaultPollInterval`). Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching`.
  func startCapture() {
    clipboardMonitor.start()
  }

  /// Registers the global ⌥⌘V hotkey (plan task T27, fix round 2) that
  /// opens the picker from anywhere, via the exact same `showPicker()` path
  /// the menu bar's "Open Clipnest" item already uses, and (T9) the global
  /// ⌥⌘E hotkey that triggers `snippetExpander`. Call exactly once, from
  /// `AppDelegate.applicationDidFinishLaunching`.
  func registerHotkey() {
    HotkeyManager.register { [weak self] in self?.showPicker() }
    HotkeyManager.registerExpandSnippet { [weak self] in
      guard let self else { return }
      Task { await self.snippetExpander.expand() }
    }

    // The picker hotkey is delivered by a Carbon hotkey while untrusted and
    // by non-consuming `NSEvent` monitors once trusted (see `HotkeyManager`'s
    // header). Both directions matter: on a grant the monitors have to be
    // installed (one created while untrusted stays permanently dead), and on
    // a revocation the Carbon hotkey has to come back or the shortcut dies.
    accessibilityWatcher.onTrustChanged = { _ in
      HotkeyManager.applyDeliveryMode()
    }
    accessibilityWatcher.start()
  }

  /// Starts the approved background 24h update-availability check. Call
  /// exactly once, from `AppDelegate.applicationDidFinishLaunching`,
  /// alongside `startCapture()`/`registerHotkey()` — construction itself
  /// stays side-effect-free (see this file's top doc comment and
  /// `UpdateChecker`'s own), so tests can build an environment with no
  /// background timer running.
  func startUpdateChecking() {
    updateChecker.start(settings: settingsStore)
  }

  /// Shows macOS's Accessibility prompt at most ONCE, ever, and only when
  /// the permission is actually missing.
  ///
  /// This is the whole "check before prompting" rule in one place: read the
  /// silent `PermissionsManager.isGranted` first and return immediately if
  /// it is already granted, then consult the persisted
  /// `SettingsStore.hasRequestedAccessibility` so a user who has already
  /// seen (and possibly dismissed) the dialog is never nagged again. Every
  /// later chance to grant it is user-initiated, from the Permissions
  /// settings tab.
  ///
  /// Called from `AppDelegate.applicationDidFinishLaunching`, after
  /// `registerHotkey()` — the hotkey genuinely cannot work without this
  /// permission as of the ⌥⌘V pass-through fix (see `HotkeyManager`), so a
  /// first-run user who is never told would just find a dead shortcut.
  func requestAccessibilityOnceIfNeeded() {
    guard !PermissionsManager.isGranted else { return }
    guard !settingsStore.hasRequestedAccessibility else { return }
    settingsStore.hasRequestedAccessibility = true
    PermissionsManager.requestAccess()
  }

  /// Shows the picker panel — the menu bar "Open Clipnest" item's action,
  /// and (fix round 2) the global hotkey's action. Both triggers share this
  /// one method; nothing about it is trigger-specific.
  ///
  /// T16: records the frontmost app *before* the panel is shown, so
  /// `PickerViewModel.select(_:)` later has the right paste target — see
  /// `FrontmostAppTracker`'s doc comment for why this must happen at
  /// trigger time rather than lazily at select time.
  func showPicker() {
    frontmostAppTracker.record()
    pickerPanel.show()
  }

  /// Trims history down to the user's configured cap once, now — called at
  /// launch (a debounced pass also runs after each capture, via
  /// `scheduleRetentionEnforcement()`). Fire-and-forget; a failure is
  /// logged (metadata only), never surfaced, since retention is
  /// best-effort housekeeping, not a user action. Pinned items are always
  /// kept (guaranteed by `enforceRetention`). Not debounced itself — this
  /// runs exactly once, at launch, so there is no burst to coalesce.
  func enforceRetentionNow() {
    let cap = settingsStore.retentionCap
    let retentionStore = clipStore
    Task {
      do {
        try await retentionStore.enforceRetention(cap: cap)
      } catch {
        Self.logger.error("retention enforcement failed at launch: \(String(describing: error))")
      }
    }
  }

  /// T-PF1 (D2 fix): schedules a single debounced `enforceRetention` pass,
  /// cancelling and replacing any pass already waiting — so a burst of N
  /// captures in quick succession (e.g. selecting and copying several items
  /// in a row) results in roughly ONE retention pass after the burst goes
  /// quiet for `retentionDebounceInterval`, not N. Called from
  /// `clipboardMonitor.onCapture` (see `init`); never called for the
  /// launch-time pass, which has no burst to coalesce (`enforceRetentionNow()`).
  ///
  /// Re-reads `settingsStore.retentionCap` AFTER the debounce delay (not at
  /// schedule time) so a setting changed mid-burst is honored by the pass
  /// that actually runs, rather than whatever was current when the first
  /// capture in the burst arrived.
  ///
  /// Cancelling a pending (still-sleeping) task reliably stops it before it
  /// calls `enforceRetention` at all. If a previous pass has already moved
  /// past the sleep and is actively running on `clipStore`'s actor when a
  /// new capture arrives, cancellation does not interrupt that in-flight
  /// actor call (it has no cancellation checkpoints) — it simply finishes,
  /// and the newly-scheduled pass runs independently after its own delay.
  /// That is an accepted, intentionally simple tradeoff for a best-effort
  /// housekeeping pass: still bounded (never more passes than there are
  /// quiet gaps in the capture stream), just not a hard guarantee of
  /// exactly one pass per burst under every possible timing.
  private func scheduleRetentionEnforcement() {
    pendingRetentionTask?.cancel()
    let retentionStore = clipStore
    pendingRetentionTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.retentionDebounceInterval)
      } catch {
        // Cancelled by a newer capture superseding this scheduled pass.
        return
      }
      guard let self else { return }
      let cap = self.settingsStore.retentionCap
      do {
        try await retentionStore.enforceRetention(cap: cap)
      } catch {
        Self.logger.error(
          "retention enforcement failed after capture: \(String(describing: error))")
      }
      self.pendingRetentionTask = nil
    }
  }
}
