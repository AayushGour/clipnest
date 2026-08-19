// UpdateChecker.swift
//
// Approved feature: a background update-AVAILABILITY check. Once every 24h
// this asks GitHub whether a newer Clipnest release exists and reports it
// via `onStateChanged` (consumed by `PickerViewModel.isUpdateAvailable`/
// `latestVersion`, shown as a small dot next to the version label in
// `PickerView.shortcutHintBar`). It never downloads or installs anything —
// download stays fully manual, through the unchanged, D35-approved
// `AppUpdater.runUpdate()` / `PickerViewModel.requestAppUpdate()` click flow.
//
// Same "Local-only, always" constraint as `AppUpdater` (coding-standards.md:
// no `URLSession`/sockets anywhere in the codebase — reviewer greps every
// diff for networking APIs). `checkNow()` makes no network call itself
// either: it spawns `/usr/bin/curl` via `Process` against the exact same
// public GitHub Releases API endpoint `scripts/update.sh` already queries
// (see that script's `RELEASE_JSON=` line), then parses the JSON reply with
// `JSONSerialization` — a real parser, unlike that bash script's own
// `grep -o '"tag_name": *"[^"]*"'` (bash has no choice; Swift does).
//
// Version comparison is a literal port of `scripts/update.sh`'s own
// `if [ "${INSTALLED}" = "${LATEST}" ]` check — not-equal-means-update-
// available, no semver library, that script stays the single source of
// truth for what "up to date" means. See `isUpdateAvailable(installed:
// latestTag:)`.
//
// Construction stays side-effect-free (no timer starts from `init`), same
// rule `AppEnvironment`'s own doc comment states for `ClipboardMonitor`/
// `HotkeyManager` — so tests can build one without a background task
// running. `start(settings:)` must be called once, post-construction, from
// `AppEnvironment`.

import Foundation

@MainActor
final class UpdateChecker {
  /// How often to re-check, per the approved design's literal "once every
  /// 24 hours" ask. No adaptive backoff/retry on failure — kept simple, see
  /// `checkNow()`'s doc comment.
  static let checkInterval: TimeInterval = 24 * 60 * 60

  /// The same public, versionless GitHub Releases API endpoint
  /// `scripts/update.sh` already queries (that script's `RELEASE_JSON=`
  /// line) — one place this URL is defined, even though this is a second,
  /// independent client of it. `nonisolated` because it's read from
  /// `fetchLatestReleaseJSON()`, which itself runs off the main actor.
  private nonisolated static let releasesAPIURL =
    "https://api.github.com/repos/AayushGour/clipnest/releases/latest"

  private enum Key {
    /// Scoped to this type, not `SettingsStore` — this is internal cache
    /// state (when did we last poll GitHub), not user-facing configuration,
    /// per the routed spec's explicit call.
    static let lastCheckedAt = "updateChecker.lastCheckedAt"
  }

  private(set) var isUpdateAvailable: Bool = false
  private(set) var latestVersion: String?

  /// Fired every time a real `checkNow()` completes successfully. Set by
  /// the composition root (`AppEnvironment`) to push `isUpdateAvailable`/
  /// `latestVersion` into `PickerViewModel` — the same plain-closure-
  /// injection pattern already used for `PickerViewModel.dismiss`/
  /// `updatePreview`/`requestAppUpdate` (not Combine, not `@Observable`).
  /// Defaults to a no-op so this type stays usable without a listener (e.g.
  /// in tests).
  var onStateChanged: (Bool, String?) -> Void = { _, _ in }

  private let defaults: UserDefaults

  /// `Timer` isn't `Sendable`, and `deinit` is nonisolated by default in
  /// Swift 6 (same situation `PickerPanel.commandDeleteMonitor` documents)
  /// — `nonisolated(unsafe)` is safe here because every mutation happens
  /// synchronously on `@MainActor` (this class's own isolation) while the
  /// instance is alive, and the only nonisolated access is the read in
  /// `deinit`, which by construction can't run concurrently with any of
  /// those writes (an object can't be deallocated while still reachable).
  private nonisolated(unsafe) var timer: Timer?

  /// Mirrors the user's latest intent (`SettingsStore
  /// .automaticallyCheckForUpdates`, as of the last `start`/
  /// `settingChanged` call). Guards against a narrow race: a one-shot timer
  /// can already be mid-`checkNow()` (awaiting curl) at the exact moment
  /// `settingChanged(enabled: false)` calls `stop()` — without this flag,
  /// that in-flight check's completion would still arm the steady-state
  /// repeating timer afterward, silently un-stopping a checker the user
  /// just disabled. See `scheduleOneShotTimer(after:)`.
  private var isEnabled = false

  /// When `checkNow()` last ran, success OR failure (see that method's doc
  /// comment) — persisted so the 24h cadence survives an app relaunch
  /// instead of re-checking on every launch. `nil` means "never checked."
  private var lastCheckedAt: Date? {
    get { defaults.object(forKey: Key.lastCheckedAt) as? Date }
    set { defaults.set(newValue, forKey: Key.lastCheckedAt) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  deinit {
    timer?.invalidate()
  }

  /// Starts the 24h background check, honoring the user's persisted
  /// `SettingsStore.automaticallyCheckForUpdates` preference at the moment
  /// of the call. Call exactly once, post-construction, from
  /// `AppEnvironment` (mirrors `ClipboardMonitor.start()`'s "no background
  /// work from `init`" rule — see this file's top doc comment).
  func start(settings: SettingsStore) {
    guard settings.automaticallyCheckForUpdates else { return }
    isEnabled = true
    scheduleTimer()
  }

  /// Stops the background check. Safe to call even if not started.
  func stop() {
    isEnabled = false
    timer?.invalidate()
    timer = nil
  }

  /// Called by the Settings UI (`GeneralSettingsView`) when the user flips
  /// "Automatically check for updates" live — starts or stops the timer
  /// immediately, rather than waiting up to 24h for the next scheduled tick
  /// to notice a disabled setting.
  func settingChanged(enabled: Bool) {
    isEnabled = enabled
    if enabled {
      scheduleTimer()
    } else {
      stop()
    }
  }

  /// If a check is already due (or none has ever run), checks immediately
  /// and arms the steady-state 24h repeating timer right away — that
  /// immediate `checkNow()` itself counts as "now," so the next tick is
  /// correctly 24h out from it, not from launch/enable time. Otherwise arms
  /// a one-shot timer for the remaining delay, which itself checks once and
  /// then hands off to the same repeating timer. No-ops if a timer is
  /// already running — `start()`/`settingChanged(enabled: true)` are both
  /// idempotent.
  private func scheduleTimer() {
    guard timer == nil else { return }
    if isCheckDue {
      Task { [weak self] in await self?.checkNow() }
      scheduleRepeatingTimer()
    } else {
      scheduleOneShotTimer(after: remainingDelay)
    }
  }

  private var isCheckDue: Bool {
    guard let lastCheckedAt else { return true }
    return Date().timeIntervalSince(lastCheckedAt) >= Self.checkInterval
  }

  private var remainingDelay: TimeInterval {
    guard let lastCheckedAt else { return 0 }
    return max(0, Self.checkInterval - Date().timeIntervalSince(lastCheckedAt))
  }

  private func scheduleOneShotTimer(after delay: TimeInterval) {
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        await self.checkNow()
        self.timer = nil
        // See `isEnabled`'s doc comment: `stop()` may have run while this
        // check was in flight — don't resurrect the timer if so.
        guard self.isEnabled else { return }
        self.scheduleRepeatingTimer()
      }
    }
  }

  private func scheduleRepeatingTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) {
      [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        await self.checkNow()
      }
    }
  }

  /// Checks GitHub once, right now. Spawns `/usr/bin/curl` (never
  /// `URLSession`) against `releasesAPIURL`, parses `tag_name` out of the
  /// JSON reply, and compares it to `AppUpdater.currentVersion`.
  ///
  /// On success: updates `isUpdateAvailable`/`latestVersion` and fires
  /// `onStateChanged`. On ANY failure — curl missing, offline, non-zero
  /// exit, malformed JSON — silently no-ops and keeps whatever state was
  /// already showing; no error UI, mirroring `AppUpdater.runUpdate()`'s own
  /// silent-fallback precedent. `lastCheckedAt` is updated in BOTH cases
  /// (the `defer` below), so a persistently-offline machine still only
  /// polls once per 24h instead of hammering on every timer tick.
  func checkNow() async {
    defer { lastCheckedAt = Date() }
    guard let data = await Self.fetchLatestReleaseJSON(),
      let tag = Self.parseTagName(fromReleaseJSON: data)
    else { return }

    let available = Self.isUpdateAvailable(installed: AppUpdater.currentVersion, latestTag: tag)
    let normalized = Self.normalizedVersion(fromTag: tag)
    isUpdateAvailable = available
    latestVersion = normalized
    onStateChanged(available, normalized)
  }

  // MARK: - Pure logic (unit-tested directly — no `Process` spawn involved)

  /// Not-equal-means-update-available — a literal port of
  /// `scripts/update.sh`'s own `if [ "${INSTALLED}" = "${LATEST}" ]` check.
  /// Deliberately no semver comparison/library: that script is the single
  /// source of truth for "what counts as up to date," and string equality
  /// after stripping a leading `v` is exactly what it already does.
  nonisolated static func isUpdateAvailable(installed: String, latestTag: String) -> Bool {
    installed != normalizedVersion(fromTag: latestTag)
  }

  /// Strips a leading `v` from a GitHub tag (`"v1.2.3"` -> `"1.2.3"`),
  /// mirroring `scripts/update.sh`'s `LATEST="${LATEST#v}"`. A tag with no
  /// `v` prefix passes through unchanged.
  nonisolated static func normalizedVersion(fromTag tag: String) -> String {
    tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
  }

  /// Extracts `tag_name` from a GitHub Releases API JSON response using
  /// `JSONSerialization` — a real parser, unlike `scripts/update.sh`'s own
  /// regex-ish `grep -o '"tag_name": *"[^"]*"'` (that script is bash and has
  /// no choice; this is Swift and does). Returns `nil` on any malformed or
  /// unexpected shape rather than throwing, so `checkNow()` can treat it
  /// exactly like every other failure mode.
  nonisolated static func parseTagName(fromReleaseJSON data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = object["tag_name"] as? String
    else { return nil }
    return tag
  }

  /// Spawns `/usr/bin/curl -fsSL releasesAPIURL` (same strategy as
  /// `AppUpdater`/`scripts/update.sh` — no `URLSession`/sockets anywhere in
  /// the codebase) and returns its captured stdout, or `nil` on any failure
  /// (missing binary, non-zero exit, offline). `nonisolated` so the
  /// synchronous `Process`/`Pipe` wait happens off the main actor — this
  /// check runs on a 24h background timer, and there's no reason to hold up
  /// the UI thread on it.
  ///
  /// Known, accepted limitation, flagged rather than silently assumed fine:
  /// `curl` is given no `--max-time`, matching `scripts/update.sh`'s own
  /// invocation exactly (kept as the single source of truth for the request
  /// shape) — a genuinely stuck connection could hold this background
  /// worker thread longer than usual. Not fixed here since it would
  /// diverge from that shared invocation and isn't part of the routed spec.
  private nonisolated static func fetchLatestReleaseJSON() async -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-fsSL", releasesAPIURL]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return nil
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return data
  }
}
