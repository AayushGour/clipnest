import ClipnestCore
import ClipnestGTK
import ClipnestLinuxOCR
import ClipnestPlatformLinux
import ClipnestSQLite
import ClipnestViewModels
import Foundation
import Synchronization

/// Clipnest's Linux composition root — the exact analogue of
/// `ClipnestApp/Sources/App/AppEnvironment.swift`, adapted to this
/// platform's real collaborators: `SQLiteClipStore`/`SQLiteSnippetStore`
/// (`ClipnestSQLite`) instead of SwiftData, `LinuxPasteboard`/
/// `X11ClipboardConnection` instead of `NSPasteboard`, and
/// `LinuxEventSynthesizerFactory`'s uinput/XTEST/clipboard-only chain
/// instead of `CGEventSynthesizer`.
///
/// **Learned from the macOS bug (D50):** `SwiftDataClipStore`/
/// `SwiftDataSnippetStore` construction used to run inline on the main
/// actor and could stall launch 15-82 seconds under a large retention cap
/// — this `init` uses the exact same fix `AppEnvironment.init` already
/// adopted: every blocking/expensive step (opening the two SQLite stores,
/// probing/opening the uinput device or an X11 `Display` for the paste
/// backend) runs inside its own `Task.detached(priority: .userInitiated)`,
/// all three racing concurrently via `async let`, so launch is bounded by
/// the SLOWEST of the three, never their sum — and this initializer itself
/// returns to its caller (`LinuxAppLifecycle`) without blocking the
/// thread the GTK main loop will run on.
///
/// **One shared `BlobStore` instance** for `clipStore` and
/// `clipboardMonitor` — same rule `AppEnvironment.swift`'s own doc comment
/// states, for the identical reason (two independently-constructed
/// `BlobStore`s pointed at the same directory today are one refactor away
/// from drifting apart).
@MainActor
final class LinuxAppEnvironment {
  private static let logger = ClipnestLogger(
    subsystem: ClipnestLog.subsystem, category: "LinuxAppEnvironment")

  let blobStore: BlobStore
  /// T-RT2: the real `SQLiteClipStore`, wrapped in a `NotifyingClipStore` —
  /// see that type's doc comment (and `AppEnvironment.clipStore`'s exact
  /// macOS mirror). Typed `any ClipStore` (not the concrete
  /// `SQLiteClipStore`) — nothing in this file reaches for SQLite-specific
  /// API on this property.
  let clipStore: any ClipStore
  let snippetStore: SQLiteSnippetStore
  let ocrBackfillViewModel: OCRBackfillViewModel
  let privacyFilter: PrivacyFilter
  let settingsStore: SettingsStore
  let pasteboardReader: PasteboardReader
  let clipboardMonitor: ClipboardMonitor
  let paster: Paster
  let frontmostAppTracker: FrontmostAppTracker
  let pickerViewModel: PickerViewModel
  let pickerWindow: PickerWindow
  let settingsWindow: SettingsWindow
  /// Linux parity pass (routed follow-up, 2026-09-06): closes the one
  /// unfilled seam that made snippets read-only on Linux — see
  /// `SnippetEditorWindow.swift`'s top doc comment. Held so `init` can wire
  /// `pickerViewModel.presentSnippetEditor` to it below; nothing else in
  /// this type reaches for it directly (mirrors `pickerWindow`/
  /// `settingsWindow`, held for the identical reason).
  let snippetEditorWindow: SnippetEditorWindow
  let snippetExpander: SnippetExpander
  let updateChecker: UpdateChecker

  /// Which paste backend `LinuxEventSynthesizerFactory` selected — logged
  /// (metadata only) at startup for support/diagnostics, and used to feed
  /// `Paster.isAccessibilityGranted`: on Linux there is no AX-style
  /// permission to check, so "granted" means "a real keystroke-injection
  /// backend is actually available" (`!= .clipboardOnly`).
  let eventSynthesizerKind: SelectedEventSynthesizerKind

  private var pendingRetentionTask: Task<Void, Never>?
  private static let retentionDebounceInterval: Duration = .milliseconds(750)

  /// The Linux port's analogue of `AppUpdater.currentVersion`
  /// (`ClipnestApp/Sources/System/AppUpdater.swift`), which reads
  /// `CFBundleShortVersionString` — this binary ships no bundle/plist, so
  /// there is nothing to read that from at runtime, and no build step
  /// substitutes a version into source today (`debian/rules` builds
  /// straight `swift build -c release`, no codegen step). Kept as ONE named
  /// constant (coding-standards.md's "no magic strings/numbers") rather than
  /// scattered: it MUST move in lockstep with `ClipnestApp/project.yml`'s
  /// `MARKETING_VERSION` and `debian/changelog`'s own upstream version —
  /// `release-linux.yml` already reads that same `MARKETING_VERSION` to
  /// version the `.deb`, so all three have to move together at every
  /// release regardless; this is simply the fourth spot, and the cheapest
  /// one to keep in sync (a single literal, greppable by the string
  /// itself). A build-time-substituted version (e.g. via `debian/rules`)
  /// would remove this manual step, but that is a packaging change outside
  /// this task's scope (`Package.swift`/`debian/rules` are not owned here).
  /// `nonisolated`: read from `updateChecker.installedVersion`'s `@Sendable
  /// () -> String` closure below, which — being `@Sendable` — cannot
  /// capture a `@MainActor`-isolated static property (this whole class is
  /// `@MainActor`, so an un-annotated `static let` here would be isolated
  /// too). Safe unconditionally: an immutable `String` literal has no
  /// actor-affinity to protect in the first place.
  private nonisolated static let installedVersion = "0.9.1"

  /// Resolves this process's own absolute executable path for
  /// `AutostartDesktopFile.setEnabled(_:executablePath:)`'s `.desktop`
  /// `Exec=` line — the session's autostart mechanism inherits neither this
  /// process's `$PATH` resolution nor its working directory.
  ///
  /// Shared with `LinuxAppLifecycle.installGSettingsFloor()`, which has the
  /// same requirement for its GSettings custom keybinding; see
  /// `OwnExecutablePath` for why the older `CommandLine.arguments.first`
  /// formula was broken for the packaged bare-command launch.
  private static func resolveOwnExecutablePath() -> String {
    OwnExecutablePath.resolve()
  }

  /// T-RT2: keeps this environment's subscription to `clipStore.changes`
  /// alive for the app's lifetime — see `AppEnvironment
  /// .clipStoreChangeSubscription`'s exact macOS mirror (including why this
  /// is `var`, not `let`, with an implicit-`nil` Optional default).
  private var clipStoreChangeSubscription: ClipStoreChangeSubscription?

  /// `PickerViewModel.isVisible` is `private` (out of this task's scope to
  /// widen), and the minimal `PickerWindow` contract exposes no visibility
  /// getter either — every trigger (D-Bus, tray, hotkey) funnels through
  /// `showPicker`/`hidePicker`/`togglePicker` below, which keep this box
  /// current; `PickerWindow`'s own `onDismiss` (fired for a GTK-side
  /// dismissal too — Esc, losing focus, whatever that type implements)
  /// also updates it, from a closure built during `init` that therefore
  /// can't capture `self` (not yet fully initialized at that point — see
  /// this file's `PickerWindow(...)` construction below) — a small boxed
  /// flag sidesteps that instead of a plain stored property. A reference
  /// type wraps the `Mutex` (rather than storing one directly) because
  /// `Mutex` is itself `~Copyable` and can only be consumed once; a class
  /// reference can be captured by BOTH `self.isPickerVisibleBox` and the
  /// `onDismiss` closure below. `onDismiss`'s calling thread isn't
  /// specified by the minimal `PickerWindow` contract, so the box is
  /// thread-safe rather than assumed main-thread-only.
  private let isPickerVisibleBox: PickerVisibilityBox
  private var isPickerVisible: Bool {
    get { isPickerVisibleBox.value }
    set { isPickerVisibleBox.value = newValue }
  }

  /// - Throws: whatever `SQLiteClipStore`/`SQLiteSnippetStore`'s
  ///   production initializers throw (typed `ClipStoreError`/
  ///   `SnippetStoreError.ioFailure`) — mirrors `AppEnvironment.init`'s
  ///   own "no safe in-app fallback if persistence can't come up" contract
  ///   exactly; surfaced to `LinuxAppLifecycle` rather than degraded.
  init() async throws {
    let visibilityBox = PickerVisibilityBox()
    self.isPickerVisibleBox = visibilityBox

    let blobStore = BlobStore(baseDirectory: BlobStore.defaultBaseDirectory())
    let privacyFilter = PrivacyFilter()
    let settingsStore = SettingsStore()
    let pasteboardReader = PasteboardReader()

    async let clipStoreSetup: SQLiteClipStore = Task.detached(priority: .userInitiated) {
      // The data directory (shared by both stores + `blobStore`'s own
      // `blobs/` subdirectory) is locked to 0700 BEFORE either store's own
      // `createDirectory` call can beat it there with a looser, umask-
      // derived mode — see `XDGRuntimeDirectories.prepare`'s doc comment
      // for why this fix lives here rather than in `ClipnestSQLite`
      // (out of this task's scope).
      try XDGRuntimeDirectories.prepare(XDGRuntimeDirectories.dataDirectory())
      return try SQLiteClipStore(blobStore: blobStore)
    }.value
    async let snippetStoreSetup: SQLiteSnippetStore = Task.detached(priority: .userInitiated) {
      try SQLiteSnippetStore()
    }.value
    async let synthesizerSetup:
      (
        synthesizer: any EventSynthesizing, kind: SelectedEventSynthesizerKind
      ) = Task.detached(priority: .userInitiated) {
        // Manual-verify only (needs real `/dev/uinput`/`X11`) — see
        // `LinuxEventSynthesizerFactory`'s own doc comment for why this must
        // run exactly once, off the main thread.
        LinuxEventSynthesizerFactory.makeDefault()
      }.value

    let (rawClipStore, snippetStore, synthesizerResult) = try await (
      clipStoreSetup, snippetStoreSetup, synthesizerSetup
    )

    // T-RT2: wraps the real store — see `NotifyingClipStore`'s doc comment,
    // and `AppEnvironment.init`'s exact macOS mirror of this same line.
    // Every consumer below receives THIS wrapped value via the `clipStore`
    // local — never `rawClipStore` directly.
    let clipStore = NotifyingClipStore(wrapping: rawClipStore)

    self.blobStore = blobStore
    self.privacyFilter = privacyFilter
    self.settingsStore = settingsStore
    self.pasteboardReader = pasteboardReader
    self.clipStore = clipStore
    self.snippetStore = snippetStore
    self.eventSynthesizerKind = synthesizerResult.kind
    Self.logger.info("paste backend selected: \(String(describing: synthesizerResult.kind))")

    let textRecognizer = OnnxTextRecognizer()
    self.ocrBackfillViewModel = OCRBackfillViewModel(
      coordinator: OCRBackfillCoordinator(
        store: clipStore, blobStore: blobStore, recognizer: textRecognizer))

    let sharedWriter = GTKClipboardWriting(
      pasteboardChangeCount: { X11ClipboardConnection.shared.changeSerial })

    let frontmostAppProvider = LinuxFrontmostAppReferenceProvider()
    let paster = Paster(
      pasteboard: sharedWriter,
      eventSynthesizer: synthesizerResult.synthesizer,
      isAccessibilityGranted: { synthesizerResult.kind != .clipboardOnly },
      frontmostAppProvider: frontmostAppProvider
    )
    self.paster = paster

    let frontmostAppTracker = FrontmostAppTracker(provider: frontmostAppProvider)
    self.frontmostAppTracker = frontmostAppTracker

    self.clipboardMonitor = ClipboardMonitor(
      store: clipStore,
      privacyFilter: privacyFilter,
      reader: pasteboardReader,
      blobStore: blobStore,
      pasteboard: LinuxPasteboard(),
      frontmostApplicationProvider: LinuxFrontmostApplicationProvider(
        ownProgramName: ClipnestControlName.programName),
      excludedBundleIDsProvider: {
        MainActor.assumeIsolated { Set(settingsStore.userExcludedBundleIDs) }
      },
      captureEnabledProvider: {
        MainActor.assumeIsolated { settingsStore.isCaptureEnabled }
      },
      textRecognizer: textRecognizer,
      textRecognitionEnabledProvider: {
        MainActor.assumeIsolated { settingsStore.isTextRecognitionEnabled }
      },
      textRecognitionQualityProvider: {
        MainActor.assumeIsolated { settingsStore.textRecognitionQuality }
      }
    )

    // `SnippetExpander`'s Accessibility-first tier: `ATSPITextAccessor`
    // needs a live a11y-bus connection; when none is reachable (no a11y
    // bus in this session, or the resolve/connect fails), this degrades to
    // `NullSelectedTextAccessing` so `SnippetExpander` falls straight
    // through to its universal clipboard-replace tier instead of crashing
    // or throwing — matches this task's "treat OCR/AX as optional, degrade
    // cleanly" directive for every optional subsystem, not just OCR.
    let selectedTextAccessing = Self.makeSelectedTextAccessing()
    let clipboardReplacer = LinuxClipboardSelectionReplacer(
      poster: synthesizerResult.synthesizer as? any SyntheticKeystrokePosting
        ?? NullSyntheticKeystrokePosting(),
      pasteboard: LinuxPasteboard(), writer: sharedWriter,
      frontmostAppProvider: frontmostAppProvider
    )
    self.snippetExpander = SnippetExpander(
      snippetStore: snippetStore, selectedText: selectedTextAccessing,
      clipboardReplacer: clipboardReplacer)

    let monitor = clipboardMonitor
    clipboardReplacer.beginSuppression = { [weak monitor] in monitor?.pause() }
    clipboardReplacer.endSuppression = { [weak monitor] in
      monitor?.ignore(changeCount: X11ClipboardConnection.shared.changeSerial)
      monitor?.resume()
    }

    let viewModel = PickerViewModel(
      clipStore: clipStore, snippetStore: snippetStore, pasteboard: sharedWriter,
      blobStore: blobStore, paster: paster, frontmostAppTracker: frontmostAppTracker,
      // T-RT2: lets an already-open picker re-query itself when SOMETHING
      // ELSE mutates this store — a Settings "Clear All History…", or
      // background retention — without either of those call sites needing
      // to know `pickerViewModel` exists.
      storeChanges: clipStore.changes)
    self.pickerViewModel = viewModel

    let pickerWindow = PickerWindow(
      viewModel: viewModel,
      onDismiss: {
        // Only the owner-side flag. `PickerWindow.dismiss()` — the single
        // path every user-initiated dismissal now routes through — has
        // already called `hide()`, which calls `viewModel.didHide()` on the
        // GTK thread before this closure runs. Calling `didHide()` again
        // here would be redundant, and doing it from a `Task { @MainActor }`
        // made it land AFTER this closure returned, so the flag and the
        // view model briefly disagreed.
        visibilityBox.value = false
      })
    self.pickerWindow = pickerWindow
    // `dismiss()`, not `hide()`: hiding alone left `visibilityBox` true, so
    // the next hotkey ran the "hide" half of `togglePicker` against an
    // already-hidden window and appeared to do nothing.
    viewModel.dismiss = { [weak pickerWindow] in pickerWindow?.dismiss() }
    viewModel.suppressOwnPasteboardWrite = { [weak monitor] changeCount in
      monitor?.ignore(changeCount: changeCount)
    }

    // Linux parity pass (routed follow-up, 2026-09-06): mirrors
    // `AppEnvironment.init`'s macOS wiring of `viewModel.presentSnippetEditor`
    // (`ClipnestApp/Sources/App/AppEnvironment.swift`) as closely as this
    // platform allows. `onSave` decides create vs. update by switching on
    // `mode` — the exact same `mode` this `presentSnippetEditor` closure was
    // just called with — matching macOS exactly; `SnippetEditorWindow` (GTK)
    // itself has no opinion on `SnippetStore`, same contract as its macOS
    // counterpart. `onClose` calls `pickerWindow.refocusAfterEditorClose()`
    // (see that method's doc comment) — the GTK counterpart of macOS's
    // `panel.makeKey(); viewModel.refocusSearchField()`. No `pickerPanel`-
    // style positioning parameter: GTK4 has no portable window-move API for
    // this window to use even if it took one (see `SnippetEditorWindow
    // .swift`'s top doc comment).
    let snippetEditorWindow = SnippetEditorWindow()
    self.snippetEditorWindow = snippetEditorWindow
    viewModel.presentSnippetEditor = {
      [weak snippetEditorWindow, weak viewModel, weak pickerWindow] mode in
      guard let snippetEditorWindow, let viewModel else { return }
      // Real bug found by this task's own runtime verification (see
      // `PickerWindow.isEditorSessionActive`'s doc comment): presenting
      // this real, activating `GtkWindow` makes the picker's OWN
      // `notify::is-active` fire `false` too, which — without this flag —
      // fully dismissed the picker (hid it AND cancelled the view model's
      // in-flight queries) instead of just losing window-manager
      // prominence, unlike macOS's side-by-side non-dismissing design.
      // Cleared inside `refocusAfterEditorClose()` itself, deferred to the
      // next main-loop idle iteration — see that method's doc comment for
      // a second, more severe real bug found in this exact handoff (a
      // synchronous close-then-present X11 grab race, 225%+ CPU) and why
      // clearing this flag early, before that deferred step runs, would
      // reopen the window `isEditorSessionActive` exists to close.
      pickerWindow?.setEditorSessionActive(true)
      snippetEditorWindow.show(
        mode: mode,
        onSave: { title, body, keyword in
          switch mode {
          case .create, .createFromClip:
            viewModel.createSnippet(title: title, body: body, keyword: keyword)
          case .edit(let snippet):
            viewModel.updateSnippet(snippet.id, title: title, body: body, keyword: keyword)
          }
        },
        onClose: { [weak pickerWindow] in
          pickerWindow?.refocusAfterEditorClose()
        })
    }

    let updateChecker = UpdateChecker()
    // P10-A: was never set — `installedVersion` defaulted to `"?"`, which
    // made `UpdateChecker.isUpdateAvailable(installed:latestTag:)`'s
    // not-equal comparison permanently `true` (a `"?"` never equals a real
    // release tag), so the picker's "update available" dot showed even on
    // the latest version. Mirrors `AppEnvironment.init`'s `updateChecker
    // .installedVersion = { AppUpdater.currentVersion }` — see
    // `Self.installedVersion`'s doc comment for why Linux has no
    // `CFBundleShortVersionString` equivalent to read this from at runtime.
    updateChecker.installedVersion = { Self.installedVersion }
    updateChecker.onStateChanged = { [weak viewModel] available, latest in
      viewModel?.isUpdateAvailable = available
      viewModel?.latestVersion = latest
    }
    self.updateChecker = updateChecker

    // P10-A: `AutostartDesktopFile` (this module) is unreachable from
    // `ClipnestGTK` — `ClipnestGTK` depends on neither `ClipnestLinuxAppKit`
    // nor anything that re-exports it (Package.swift's dependency edge runs
    // the other way: `ClipnestLinuxAppKit -> ClipnestGTK`; the reverse would
    // be a cycle). So `SettingsWindow` gets the launch-at-login capability
    // as two plain closures, resolved here at the composition root — the
    // same "inject a closure across a module boundary" shape already used
    // for `captureEnabledProvider`/`excludedBundleIDsProvider` above and
    // `placeWindowHandler` below, not a new pattern.
    let resolvedExecutablePath = Self.resolveOwnExecutablePath()

    self.settingsWindow = SettingsWindow(
      settings: settingsStore,
      updateChecker: updateChecker,
      clipStore: clipStore,
      ocrBackfillViewModel: ocrBackfillViewModel,
      launchAtLoginProvider: { AutostartDesktopFile.isEnabled() },
      setLaunchAtLogin: { enabled in
        try AutostartDesktopFile.setEnabled(enabled, executablePath: resolvedExecutablePath)
      },
      // T-OPT2 (a concurrent agent's Settings > Shortcuts rebinding work):
      // required, no default — same module as this file, so no import
      // needed. `ToggleHotkeyFloorBinding`/`Hotkeys/**` are that agent's
      // files, not this one's; only this call site's new argument is mine.
      reinstallToggleHotkeyFloor: { accelerator in
        ToggleHotkeyFloorBinding.reinstallFloor(withAccelerator: accelerator)
      })

    monitor.onCapture = { [weak self, weak viewModel] _ in
      viewModel?.handleNewCapture()
      self?.scheduleRetentionEnforcement()
    }

    // T-RT2/T-HANG6: forwards every deletion/full-clear this store observes
    // — regardless of which call site caused it (`pickerViewModel
    // .delete(_:)`/`deleteHighlighted()` above, or a Settings "Clear All
    // History…" call once wired to this same injected `clipStore`) — into
    // `clipboardMonitor`'s existing (T-HANG5) pending-OCR cancellation, so a
    // still-scheduled recognition job never outlives the row it targets.
    // `[weak monitor]` (the same local already used above), not `[weak
    // self]`: see `AppEnvironment`'s exact macOS mirror of this subscription
    // for why capturing `self` at an earlier point in this initializer trips
    // Swift's definite-initialization check.
    self.clipStoreChangeSubscription = clipStore.changes.subscribe { [weak monitor] change in
      Task { @MainActor in
        guard let monitor else { return }
        switch change {
        case .deleted(let id):
          monitor.cancelPendingRecognition(for: id)
        case .clearedAll:
          monitor.cancelAllPendingRecognition()
        case .inserted, .updated, .retentionApplied:
          break
        }
      }
    }

    // Event-driven capture (P2-A): the X11/XFixes backend calls this
    // closure on ITS OWN background event thread the instant it observes
    // a real selection-ownership change — never the GTK/main thread. The
    // `Task { @MainActor in ... }` hop is exactly what
    // `GTKMainActorBridge`/`DispatchMainQueuePump` exists to make actually
    // resume (see that type's doc comment) — this is the single most
    // frequent real-world exercise of that mechanism in the whole app.
    X11ClipboardConnection.shared.onSelectionChanged = { [weak monitor] _, _ in
      Task { @MainActor in _ = await monitor?.checkNow() }
    }
  }

  /// Attempts to stand up the AT-SPI Accessibility-first tier for
  /// `SnippetExpander`: resolves the a11y bus address off the session bus,
  /// connects, and starts an `ATSPIFocusTracker`. Real, manual-verify-only
  /// D-Bus I/O — see `ATSPITextAccessor`/`ATSPIFocusTracker`'s own doc
  /// comments; degrades to `NullSelectedTextAccessing` on any failure
  /// (missing `DBUS_SESSION_BUS_ADDRESS`, unreachable a11y bus, ...).
  private static func makeSelectedTextAccessing() -> any SelectedTextAccessing {
    guard
      let sessionBusAddress = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
      let a11yAddress = AccessibilityBusResolver.resolveAddress(
        sessionBusAddress: sessionBusAddress),
      let callConnection = DBusConnection.connect(address: a11yAddress, timeout: .seconds(1)),
      let signalConnection = DBusConnection.connect(address: a11yAddress, timeout: .seconds(1))
    else {
      logger.info("AT-SPI accessibility bus unavailable — snippet expansion is clipboard-only")
      return NullSelectedTextAccessing()
    }

    let focusTracker = ATSPIFocusTracker(connection: signalConnection)
    focusTracker.start()
    return ATSPITextAccessor(
      caller: callConnection, focusedObject: { focusTracker.currentFocusedObject() },
      nextSerial: { callConnection.allocateSerial() })
  }

  /// Starts real clipboard capture. Call exactly once, from
  /// `LinuxAppLifecycle.run()`.
  func startCapture() {
    clipboardMonitor.startEventDriven()
  }

  func startUpdateChecking() {
    updateChecker.start(settings: settingsStore)
  }

  /// Set by `LinuxAppLifecycle` once a `ShellHelperClient` exists — see
  /// `PickerWindow.swift`'s own doc comment (the OTHER agent's file):
  /// GTK4 dropped `gtk_window_move`/keep-above/skip-taskbar entirely (no
  /// Wayland equivalent), so `windowToken` exists specifically so
  /// `ClipnestLinuxApp` can ask the Shell extension's
  /// `PlaceWindow(window_token, x, y, flags)` to do it via Mutter — the
  /// only thing that can, on a Wayland session. Defaults to a no-op so a
  /// picker with no extension installed still opens (compositor-default
  /// placement), just not pointer-anchored.
  var placeWindowHandler: (_ windowToken: String, _ x: Int, _ y: Int) -> Void = { _, _, _ in }

  /// Shows the picker — mirrors `AppEnvironment.showPicker()`'s single
  /// choke point for every trigger (D-Bus `TogglePicker`/`ShowPicker`, the
  /// tray's "Open Clipnest", a hotkey). `willShow()` is called explicitly
  /// here (rather than from a GTK-side hook, which the minimal
  /// `PickerWindow` contract doesn't expose) since this IS the one place
  /// every trigger already funnels through.
  func showPicker(at point: (x: Int, y: Int)?) {
    frontmostAppTracker.record()
    pickerViewModel.willShow()
    pickerWindow.show(at: point)
    if let point {
      placeWindowHandler(pickerWindow.windowToken, point.x, point.y)
    }
    isPickerVisible = true
  }

  func hidePicker() {
    pickerWindow.hide()
    isPickerVisible = false
  }

  func togglePicker(at point: (x: Int, y: Int)? = nil) {
    if isPickerVisible {
      hidePicker()
    } else {
      showPicker(at: point)
    }
  }

  func openSettings() {
    settingsWindow.show()
  }

  func expandSnippet() {
    Task { await snippetExpander.expand() }
  }

  /// Mirrors `AppEnvironment.enforceRetentionNow()` exactly (best-effort,
  /// logged not surfaced) — run once at launch.
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

  /// Mirrors `AppEnvironment.scheduleRetentionEnforcement()` exactly — see
  /// that method's doc comment for the debounce reasoning (T-PF1/D2).
  private func scheduleRetentionEnforcement() {
    pendingRetentionTask?.cancel()
    let retentionStore = clipStore
    pendingRetentionTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.retentionDebounceInterval)
      } catch {
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

/// Degrades `SnippetExpander`'s Accessibility-first tier to "never
/// readable" when no a11y bus connection could be established — see
/// `LinuxAppEnvironment.makeSelectedTextAccessing()`. `ClipnestCore` has no
/// portable default for this protocol the way it does for
/// `EventSynthesizing`'s `NoOpEventSynthesizing` (`SelectedTextAccessing`'s
/// concrete implementations are always app-layer, per that protocol's own
/// doc comment), so this app supplies its own.
private struct NullSelectedTextAccessing: SelectedTextAccessing {
  func readSelectedText() -> String? { nil }
  @discardableResult
  func replaceSelectedText(with text: String) -> Bool { false }
}

/// Degrades `LinuxClipboardSelectionReplacer`'s synthesized Copy/Paste to
/// "always fails" on the rare event `LinuxEventSynthesizerFactory
/// .makeDefault()`'s result doesn't ALSO conform to
/// `SyntheticKeystrokePosting` — true today only for
/// `NullClipboardOnlyEventSynthesizer` (which by construction never should
/// need to post a raw chord anyway, since `Paster` itself already reports
/// `.eventPostFailed` for that backend).
private struct NullSyntheticKeystrokePosting: SyntheticKeystrokePosting {
  @discardableResult
  func post(_ chord: KeyChord) -> Bool { false }
}

/// A thread-safe `Bool` box — see `LinuxAppEnvironment.isPickerVisibleBox`'s
/// doc comment for why this wraps `Mutex<Bool>` in a reference type rather
/// than storing the (`~Copyable`) `Mutex` directly: a class reference can
/// be captured by more than one closure/property, a noncopyable value
/// cannot.
private final class PickerVisibilityBox: @unchecked Sendable {
  private let mutex = Mutex<Bool>(false)
  var value: Bool {
    get { mutex.withLock { $0 } }
    set { mutex.withLock { $0 = newValue } }
  }
}
