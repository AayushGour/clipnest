// SettingsWindow+General.swift
//
// P7-D (Linux port, GTK4 view layer): the General settings tab — the
// GTK counterpart of macOS's `GeneralSettingsView`. Backed directly by
// `SettingsStore`, except launch-at-login (P10-A), whose state is the
// `.desktop` file's own existence — see `launchAtLoginProvider`/
// `setLaunchAtLogin`'s doc comment on `SettingsWindow` for why nothing here
// is mirrored into `SettingsStore`, matching macOS's `LaunchAtLoginController`
// semantics exactly.
//
// `@MainActor` on this method (see `SettingsWindow.swift`'s top doc
// comment): reads `settings.*`/`launchAtLoginProvider()` directly to seed
// each control's initial state. The `onToggled` closures passed to
// `addCheckButton` are `@escaping` and get invoked later, from a
// non-isolated `@convention(c)` trampoline (`SettingsWindow+Controls.swift`)
// — so, unlike the initial reads above them, each closure body wraps its
// own write in `MainActor.assumeIsolated` rather than relying on this
// method's own isolation (which does not extend to a closure invoked from
// elsewhere).
//
// T-LXUPD: `import CGtk4` is new to this file — everything before this task
// reached GTK only through `SettingsWindow+Controls.swift`'s shared,
// module-internal shims (`addCheckButton`/`addButton`/etc., visible here
// with no import since they're in the same `ClipnestGTK` module), but
// `gtk_label_set_selectable` (used by the update section's copyable apt-
// command label below) has no existing shim and is called directly on the
// raw C import instead — same "no dedicated Swift type, plain `OpaquePointer`
// already" `GtkLabel` case `Interop/GTKShims.swift`'s top doc comment
// documents for `gtk_label_set_text`/`_set_wrap`/etc. — which requires this
// file to import the module itself.
import CGtk4

// MARK: - T-LXUPD: Linux self-update types + presentation logic
//
// Lives here, not in `ClipnestLinuxAppKit`'s new `LinuxAppUpdater.swift`,
// for the same module-layering reason `UInputPermissionStatus`/
// `UInputGrantOutcome` live in `SettingsWindow+Permissions.swift`: `ClipnestGTK`
// sits BELOW `ClipnestLinuxAppKit` in the dependency graph and cannot import
// it, so a type this tab's own presentation logic needs to switch on has to
// live here — the higher module imports `ClipnestGTK` to construct/return
// values of these types instead.

/// How Clipnest is currently installed on this machine, as reported by
/// `apt-cache policy <package>` — see `LinuxAppUpdater.detectProvenance()`/
/// `AptPolicyParsing` (`ClipnestLinuxAppKit`) for how this is actually
/// determined and verified.
public enum LinuxUpdateProvenance: Equatable, Sendable {
  /// Owned by an apt repository (a PPA or any other configured origin) —
  /// `origin` is that origin's own description line from `apt-cache
  /// policy`'s output (e.g. a PPA URL), so the explanation names WHICH
  /// source owns the install, not just that one does.
  case packageManaged(origin: String)
  /// Installed from a raw `.deb` with no repository serving it — the only
  /// case where an in-app download+install is appropriate.
  case standaloneDebInstall
  /// Detection failed or didn't parse — deliberately NOT treated as
  /// `.standaloneDebInstall` (see `LinuxAppUpdater.detectProvenance()`'s
  /// doc comment: fail-safe, not fail-open). `reason` is a plain
  /// diagnostic, shown alongside a pointer to the public releases page.
  case undetermined(reason: String)
}

/// One step of `LinuxAppUpdater.performUpdate(...)`'s download+verify+install
/// flow, reported via its `onStep` callback so the tab can show live
/// progress rather than a single, long silent pause.
public enum LinuxUpdateStep: Equatable, Sendable {
  case checkingLatestRelease
  case downloadingUpdate
  case verifyingChecksum
  /// Covers BOTH waiting for polkit's authentication dialog and the actual
  /// `apt-get install` run — `pkexec` is one blocking call with no
  /// observable boundary between the two, so this deliberately does not
  /// invent a finer-grained step it can't actually detect.
  case installing
}

/// Every way `LinuxAppUpdater.performUpdate(...)` can fail short of a
/// successful install — see coding-standards.md's "typed `throws` with
/// per-module `Error` enums" pattern (this isn't `throws` itself, since
/// `LinuxUpdateOutcome` already carries success/failure as a value, but the
/// same "specific cases, not a bare String" discipline applies).
public enum LinuxAppUpdaterError: Error, Equatable, Sendable {
  case noReleaseFound
  case noMatchingAssetFound
  case noChecksumPublished
  case downloadFailed(String)
  case checksumMismatch
  /// `pkexec` reported the authentication dialog was dismissed/denied
  /// (verified exit code 126 — see `LinuxAppUpdater`'s
  /// `runPkexecAptGetInstall(debPath:)` doc comment).
  case installationCancelled
  case installationFailed(String)
}

/// The result of one `LinuxAppUpdater.performUpdate(...)` run.
public enum LinuxUpdateOutcome: Equatable, Sendable {
  case upToDate
  case succeeded(installedVersion: String)
  case failed(LinuxAppUpdaterError)
}

/// Pure presentation logic for the General tab's update section — separated
/// from GTK widget code, mirroring `PermissionsTabPresentation`'s identical
/// split, so the actual copy/gating decisions are unit-tested directly.
public enum UpdateSettingsPresentation {
  public static func versionLine(installedVersion: String) -> String {
    "Clipnest v\(installedVersion)"
  }

  public static func updateAvailableLine(latestVersion: String) -> String {
    "Update to v\(latestVersion) available"
  }

  public static let upToDateText = "You're up to date."
  public static let detectingInstallSourceText = "Checking how Clipnest was installed…"

  public static func packageManagedExplanation(origin: String) -> String {
    "Managed by apt (from \(origin)) — update it the same way, not in-app: "
  }

  public static let standaloneInstallExplanation =
    "Installed from a downloaded .deb, not a repository — Clipnest can install this update itself."

  public static func undeterminedExplanation(reason: String) -> String {
    "Couldn't tell how Clipnest was installed (\(reason)). Update manually: \(releasesPageURL)"
  }

  /// Combines `updateAvailableLine(latestVersion:)` with the
  /// provenance-specific explanation above — the single string
  /// `SettingsWindow+General.swift` shows once provenance detection
  /// resolves.
  public static func explanation(for provenance: LinuxUpdateProvenance, latestVersion: String)
    -> String
  {
    let provenanceText: String
    switch provenance {
    case .packageManaged(let origin): provenanceText = packageManagedExplanation(origin: origin)
    case .standaloneDebInstall: provenanceText = standaloneInstallExplanation
    case .undetermined(let reason): provenanceText = undeterminedExplanation(reason: reason)
    }
    return "\(updateAvailableLine(latestVersion: latestVersion)) — \(provenanceText)"
  }

  public static let releasesPageURL = "https://github.com/AayushGour/clipnest/releases"

  public static let checkForUpdatesButtonLabel = "Check for Updates Now"
  public static let installUpdateButtonLabel = "Install Update…"
  public static let confirmInstallTitle = "Install update?"
  public static let confirmInstallLabel = "Install Update"

  public static func confirmInstallMessage(latestVersion: String) -> String {
    "Download and install Clipnest v\(latestVersion) now? "
      + "You'll be asked to authenticate to complete the install."
  }

  public static func statusText(for step: LinuxUpdateStep) -> String {
    switch step {
    case .checkingLatestRelease: return "Checking the latest release…"
    case .downloadingUpdate: return "Downloading update…"
    case .verifyingChecksum: return "Verifying checksum…"
    case .installing: return "Installing — you may be asked to authenticate…"
    }
  }

  public static func statusText(for outcome: LinuxUpdateOutcome) -> String {
    switch outcome {
    case .upToDate:
      return "Already up to date."
    case .succeeded(let version):
      return "Installed v\(version) — restart Clipnest to finish updating."
    case .failed(let error):
      return "Update failed: \(message(for: error))"
    }
  }

  public static func message(for error: LinuxAppUpdaterError) -> String {
    switch error {
    case .noReleaseFound:
      return "couldn't find the latest release."
    case .noMatchingAssetFound:
      return "no build is published for this system's architecture/series."
    case .noChecksumPublished:
      return "the release has no published checksum — refusing to install an unverified file."
    case .downloadFailed(let message):
      return "download failed (\(message))."
    case .checksumMismatch:
      return "the downloaded file's checksum didn't match — refusing to install it."
    case .installationCancelled:
      return "authentication was cancelled or denied."
    case .installationFailed(let message):
      return message
    }
  }
}

extension SettingsWindow {
  @MainActor
  func buildGeneralTab() {
    let box = appendTab(title: "General")

    addCheckButton(
      to: box, label: "Enable clipboard capture",
      initialValue: settings.isCaptureEnabled
    ) { [settings] isEnabled in
      MainActor.assumeIsolated {
        settings.isCaptureEnabled = isEnabled
      }
    }

    // P10-A: launch at login. `AutostartDesktopFile` is complete, XDG-spec-
    // correct, and unit-tested (`AppAutostartDesktopFileTests`) but had zero
    // call sites before this task. Matches macOS's `GeneralSettingsView`
    // semantics exactly: the checkbox reflects the REAL filesystem state
    // (`launchAtLoginProvider()`), and a failed write reverts it rather
    // than lying about what's actually registered.
    let launchAtLoginCheckButton = addCheckButton(
      to: box, label: "Launch Clipnest at login",
      initialValue: launchAtLoginProvider()
    ) { [weak self] isEnabled in
      MainActor.assumeIsolated {
        self?.setLaunchAtLoginFromUI(isEnabled)
      }
    }
    self.launchAtLoginCheckButton = launchAtLoginCheckButton
    let launchAtLoginErrorLabel = addErrorLabel(to: box)
    self.launchAtLoginErrorLabel = launchAtLoginErrorLabel

    addCheckButton(
      to: box, label: "Automatically check for updates",
      initialValue: settings.automaticallyCheckForUpdates
    ) { [settings, updateChecker] isEnabled in
      MainActor.assumeIsolated {
        settings.automaticallyCheckForUpdates = isEnabled
        // P10-A: was written to `SettingsStore` but never actually applied
        // to the running `UpdateChecker` — turning this off did nothing
        // until the next full app restart. Mirrors `GeneralSettingsView`'s
        // own `.onChange(of: settings.automaticallyCheckForUpdates)` call
        // to `updateChecker.settingChanged(enabled:)`.
        updateChecker.settingChanged(enabled: isEnabled)
      }
    }

    buildUpdateSection(in: box)
  }

  // MARK: - T-LXUPD: Linux self-update

  /// Builds every widget the update section needs, all reconciled by
  /// `refreshUpdateAvailabilityUI()` right after (called once here, and
  /// again from `SettingsWindow.show()` — mirrors
  /// `SettingsWindow+Permissions.swift`'s `refreshPermissionsStatus()`
  /// cadence: this state only changes via the background 24h checker, this
  /// section's own "Check for Updates Now" button, or a completed install,
  /// none of which happen while Settings is closed and unwatched, so a
  /// refresh on build + on every `show()` is enough — no continuous poll).
  @MainActor
  private func buildUpdateSection(in box: OpaquePointer) {
    let updateVersionLabel = addStatusLabel(to: box)
    self.updateVersionLabel = updateVersionLabel

    addButton(to: box, label: UpdateSettingsPresentation.checkForUpdatesButtonLabel) {
      [weak self] in
      MainActor.assumeIsolated {
        self?.checkForUpdatesFromUI()
      }
    }

    let updateExplanationLabel = addStatusLabel(to: box)
    self.updateExplanationLabel = updateExplanationLabel

    // Selectable (copyable) but not editable — GTK's plain way to show
    // read-only text a user can select/copy, used here for the apt command
    // rather than a `GtkEntry` (which would also invite editing a command
    // that must be run verbatim). `GtkLabel` gets no dedicated Swift type
    // in this build (see `Interop/GTKShims.swift`'s top doc comment), so
    // `gtk_label_set_selectable` needs no shim, same as
    // `gtk_label_set_text`/`gtk_label_set_wrap` above it.
    let updateAptCommandLabel = addStatusLabel(to: box)
    gtk_label_set_selectable(updateAptCommandLabel, 1)
    self.updateAptCommandLabel = updateAptCommandLabel

    let updateInstallButton = addButton(
      to: box, label: UpdateSettingsPresentation.installUpdateButtonLabel
    ) { [weak self] in
      MainActor.assumeIsolated {
        self?.confirmInstallUpdate()
      }
    }
    gtk_widget_set_visible(updateInstallButton, 0)
    self.updateInstallButton = updateInstallButton

    let updateStatusLabel = addStatusLabel(to: box)
    self.updateStatusLabel = updateStatusLabel

    refreshUpdateAvailabilityUI()
  }

  /// Reconciles every update-section widget against
  /// `updateChecker.isUpdateAvailable`/`latestVersion` (already live —
  /// `SettingsWindow` holds `updateChecker` directly, and both properties
  /// are `public` on `UpdateChecker`, so no injected closure is needed for
  /// THIS part, unlike provenance detection below). Called once at
  /// tab-build time and again from `show()`.
  @MainActor
  func refreshUpdateAvailabilityUI() {
    guard let updateVersionLabel else { return }
    setStatusLabel(
      updateVersionLabel,
      text: UpdateSettingsPresentation.versionLine(installedVersion: installedVersionText))

    guard updateChecker.isUpdateAvailable, let latestVersion = updateChecker.latestVersion else {
      if let updateExplanationLabel {
        setStatusLabel(updateExplanationLabel, text: UpdateSettingsPresentation.upToDateText)
      }
      if let updateAptCommandLabel { setStatusLabel(updateAptCommandLabel, text: nil) }
      if let updateInstallButton { gtk_widget_set_visible(updateInstallButton, 0) }
      if let updateStatusLabel { setStatusLabel(updateStatusLabel, text: nil) }
      return
    }

    if let updateExplanationLabel {
      setStatusLabel(
        updateExplanationLabel,
        text: UpdateSettingsPresentation.updateAvailableLine(latestVersion: latestVersion)
          + " — " + UpdateSettingsPresentation.detectingInstallSourceText)
    }
    if let updateAptCommandLabel { setStatusLabel(updateAptCommandLabel, text: nil) }
    if let updateInstallButton { gtk_widget_set_visible(updateInstallButton, 0) }

    // Provenance detection is real I/O (`apt-cache policy`, `ClipnestLinuxAppKit`)
    // — never called from a synchronous widget-build path. Hops back via
    // `Task { @MainActor in ... }` before touching any widget, matching
    // `requestUInputGrantFromUI()`'s identical shape.
    let detectProvenance = detectUpdateProvenance
    Task { @MainActor [weak self] in
      let provenance = await detectProvenance()
      self?.applyDetectedProvenance(provenance, latestVersion: latestVersion)
    }
  }

  @MainActor
  private func applyDetectedProvenance(_ provenance: LinuxUpdateProvenance, latestVersion: String) {
    if let updateExplanationLabel {
      setStatusLabel(
        updateExplanationLabel,
        text: UpdateSettingsPresentation.explanation(for: provenance, latestVersion: latestVersion)
      )
    }
    switch provenance {
    case .packageManaged:
      if let updateAptCommandLabel {
        setStatusLabel(updateAptCommandLabel, text: aptUpgradeCommand)
      }
      if let updateInstallButton { gtk_widget_set_visible(updateInstallButton, 0) }
    case .standaloneDebInstall:
      if let updateAptCommandLabel { setStatusLabel(updateAptCommandLabel, text: nil) }
      if let updateInstallButton {
        gtk_widget_set_visible(updateInstallButton, 1)
        gtk_widget_set_sensitive(updateInstallButton, 1)
      }
    case .undetermined:
      if let updateAptCommandLabel { setStatusLabel(updateAptCommandLabel, text: nil) }
      if let updateInstallButton { gtk_widget_set_visible(updateInstallButton, 0) }
    }
  }

  /// `GtkButton::clicked` on "Check for Updates Now" — runs the SAME
  /// `updateChecker.checkNow()` the background 24h timer already calls (no
  /// second implementation), then re-reconciles this section from its
  /// (possibly now-changed) result.
  @MainActor
  private func checkForUpdatesFromUI() {
    let checker = updateChecker
    Task { @MainActor [weak self] in
      await checker.checkNow()
      self?.refreshUpdateAvailabilityUI()
    }
  }

  /// `GtkButton::clicked` on "Install Update…" — shows the mandatory
  /// confirmation before downloading/installing anything, mirroring
  /// `confirmClearHistory()`'s identical shape
  /// (`SettingsWindow+History.swift`). This dialog, plus polkit's own
  /// authentication dialog inside `performLinuxAppUpdate`, are the two real
  /// consent points — see `LinuxAppUpdater`'s top doc comment: never
  /// automatic.
  @MainActor
  private func confirmInstallUpdate() {
    guard let latestVersion = updateChecker.latestVersion else { return }
    showConfirmationDialog(
      title: UpdateSettingsPresentation.confirmInstallTitle,
      message: UpdateSettingsPresentation.confirmInstallMessage(latestVersion: latestVersion),
      confirmLabel: UpdateSettingsPresentation.confirmInstallLabel
    ) { [weak self] in
      MainActor.assumeIsolated {
        self?.startInstallUpdate()
      }
    }
  }

  @MainActor
  private func startInstallUpdate() {
    if let updateInstallButton { gtk_widget_set_sensitive(updateInstallButton, 0) }
    if let updateStatusLabel {
      setStatusLabel(
        updateStatusLabel, text: UpdateSettingsPresentation.statusText(for: .checkingLatestRelease)
      )
    }

    let performUpdate = performLinuxAppUpdate
    Task { @MainActor [weak self] in
      let outcome = await performUpdate { step in
        Task { @MainActor in
          self?.applyUpdateStep(step)
        }
      }
      self?.applyUpdateOutcome(outcome)
    }
  }

  @MainActor
  private func applyUpdateStep(_ step: LinuxUpdateStep) {
    guard let updateStatusLabel else { return }
    setStatusLabel(updateStatusLabel, text: UpdateSettingsPresentation.statusText(for: step))
  }

  @MainActor
  private func applyUpdateOutcome(_ outcome: LinuxUpdateOutcome) {
    if let updateStatusLabel {
      setStatusLabel(updateStatusLabel, text: UpdateSettingsPresentation.statusText(for: outcome))
    }
    if let updateInstallButton { gtk_widget_set_sensitive(updateInstallButton, 1) }
  }

  /// Writes the launch-at-login `.desktop` file (or removes it) and, on
  /// failure, reverts the checkbox to whatever the filesystem actually says
  /// — never lets the UI show a state that isn't real. Mirrors
  /// `GeneralSettingsView`'s identical `do`/`catch`/revert shape.
  @MainActor
  private func setLaunchAtLoginFromUI(_ isEnabled: Bool) {
    do {
      try setLaunchAtLogin(isEnabled)
      if let launchAtLoginErrorLabel {
        setStatusLabel(launchAtLoginErrorLabel, text: nil)
      }
    } catch {
      if let launchAtLoginErrorLabel {
        setStatusLabel(launchAtLoginErrorLabel, text: String(describing: error))
      }
      if let launchAtLoginCheckButton {
        gtk_check_button_set_active(launchAtLoginCheckButton, launchAtLoginProvider() ? 1 : 0)
      }
    }
  }
}
