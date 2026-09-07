# ClipnestLinuxAppKit — API reference

Linux-only (`#if os(Linux)`, see `Package.swift`). `ClipnestLinuxAppKit` is
the Linux composition root — the exact analogue of `ClipnestApp/Sources/App`
on macOS — plus the real, privileged/system-facing implementations that
`ClipnestGTK`'s view layer injects across the module boundary (`ClipnestGTK`
sits below this module in the dependency graph and cannot import it). This
page documents the pieces genuinely reusable outside the composition root
itself; it does not attempt to document `LinuxAppEnvironment`'s full wiring
(that's the app's own `init`, not a contract other code holds).

This is the API/usage-reference slice of the project's docs — see
[`docs/API-ClipnestGTK.md`](API-ClipnestGTK.md) for the GTK4 view layer this
module drives, and [`docs/API.md`](API.md) for the shared, cross-platform
`ClipnestCore` contract underneath both.

## Contents
- [`LinuxAppUpdater`](#linuxappupdater)
- [Working example](#working-example)

## `LinuxAppUpdater`

The Linux analogue of macOS's `ClipnestApp/Sources/System/AppUpdater.swift`
— see that file's own doc comment for the shared design intent ("the user
chooses when to update," never automatic). Same "Local-only, always"
constraint as `UpdateChecker`/`GrantInputHelperClient`: every network call
is `/usr/bin/curl` via `Process` (never `URLSession`/`FoundationNetworking`).

```swift
public enum LinuxAppUpdater {
  public static let packageName: String   // "clipnest"

  // Provenance detection
  public static func detectProvenance(packageName: String = packageName) async
    -> LinuxUpdateProvenance
  public static func aptUpgradeCommand(packageName: String = packageName) -> String

  // System facts
  public static func currentArchitecture() async -> String?
  public static func currentSeries(osReleasePath: String = "/etc/os-release") -> String?

  // Download + checksum-verify + install (only ever reached for .standaloneDebInstall)
  public static func performUpdate(
    installedVersion: String,
    packageName: String = packageName,
    onStep: @escaping @Sendable (LinuxUpdateStep) -> Void
  ) async -> LinuxUpdateOutcome
}
```

`LinuxUpdateProvenance`/`LinuxUpdateStep`/`LinuxUpdateOutcome`/
`LinuxAppUpdaterError` are declared in `ClipnestGTK`
(`SettingsWindow+General.swift`) — the tab that needs to switch on them —
not in this module; see [`docs/API-ClipnestGTK.md`](API-ClipnestGTK.md#settingswindow)
for their cases. `LinuxAppUpdater` imports `ClipnestGTK` purely to
construct/return values of those types, the same pattern
`UInputPermissionChecker`/`GrantInputHelperClient` already use for
`UInputPermissionStatus`/`UInputGrantOutcome`.

### `detectProvenance(packageName:)`

Runs `apt-cache policy <package>` and decides whether the INSTALLED version
is served by any configured apt origin (a PPA or any other repository) or
only by dpkg's own local status database:

- **`.packageManaged(origin:)`** — some configured apt source serves the
  installed version; `origin` is that source's own description line from
  `apt-cache policy`'s output (e.g. a PPA URL). Self-updating here would
  fight `apt`/the PPA for a package it owns — the correct move is `apt
  update && apt install --only-upgrade <package>` (see
  `aptUpgradeCommand(packageName:)`), not an in-app install.
- **`.standaloneDebInstall`** — installed via a raw `.deb` (`dpkg -i` /
  `apt-get install ./file.deb`) with no repository serving it. The only
  case where `performUpdate(...)` is appropriate.
- **`.undetermined(reason:)`** — detection failed (missing `apt-cache`,
  unparseable output) or the package isn't known to dpkg at all.
  Deliberately **not** treated as `.standaloneDebInstall` — fail-safe, not
  fail-open: offering an in-app install when this code simply couldn't
  tell risks fighting a repository it failed to notice.

Verified for real (not assumed) against a throwaway `ubuntu:22.04`
container in both states — see `AptPolicyParsing`'s doc comment
(`Sources/ClipnestLinuxAppKit/App/LinuxAppUpdater.swift`) for the exact
captured transcripts this parser is built from, and
`Tests/ClipnestPlatformLinuxTests/AppLinuxAppUpdaterTests.swift` for the
pinned regression cases (including a follow-on uninstalled candidate
version at a *different* indentation, which an earlier, buggier version of
this parser misread as a fabricated origin).

### `performUpdate(installedVersion:packageName:onStep:)`

Only ever called after the caller's own **explicit** "Install Update…"
confirmation — never automatically. Steps, reported via `onStep` (may run
on any thread — hop to your own actor/thread before touching UI):

1. `.checkingLatestRelease` — queries the same public GitHub Releases API
   `UpdateChecker` already polls; short-circuits to `.upToDate` if the
   latest tag equals `installedVersion`.
2. `.downloadingUpdate` — selects the `.deb` asset matching this machine's
   real architecture (`dpkg --print-architecture`) and series
   (`/etc/os-release`'s `VERSION_CODENAME`), fetches its published
   `<name>.sha256` checksum text, then downloads the `.deb` itself.
   **Fails closed** (`.noChecksumPublished`) if no checksum asset exists —
   a missing checksum is never treated as "probably fine."
3. `.verifyingChecksum` — hashes the downloaded bytes via
   `BlobStore.contentHash(of:)` (`ClipnestCore`, the project's one
   canonical SHA-256-hex helper) and compares to the published digest.
   **A mismatch (`.checksumMismatch`) returns immediately — `pkexec` is
   never invoked.** Verified for real: a test harness that corrupts one
   byte of a served `.deb` (checksum file left pointing at the original
   good bytes) observes `.checksumMismatch` and an empty
   pkexec-invocation log, while an unmodified file reaches step 4 and a
   real `pkexec` invocation is logged.
4. `.installing` — runs `pkexec apt-get install -y <path>` (the `-y`
   silences apt's own redundant re-confirmation prompt; it is not a second
   consent gate — the two real consent points are the caller's own
   confirmation dialog before this function is ever called, and polkit's
   authentication dialog inside this exact `pkexec` invocation). Exit code
   `126` (per `pkexec(1)`'s own documented contract, verified for real
   against Ubuntu 22.04's `policykit-1`) maps to
   `.failed(.installationCancelled)`; any other non-zero exit is
   `.failed(.installationFailed(<captured stderr/stdout>))` — never
   swallowed.

`LinuxUpdateOutcome` is `.upToDate` / `.succeeded(installedVersion:)` /
`.failed(LinuxAppUpdaterError)`.

## Working example

```swift
// Composition root (LinuxAppEnvironment.init) — wiring SettingsWindow's
// required, non-defaulted update seam:
SettingsWindow(
  // ...
  installedVersionText: Self.installedVersion,
  detectUpdateProvenance: { await LinuxAppUpdater.detectProvenance() },
  performLinuxAppUpdate: { onStep in
    await LinuxAppUpdater.performUpdate(installedVersion: Self.installedVersion, onStep: onStep)
  },
  aptUpgradeCommand: LinuxAppUpdater.aptUpgradeCommand())
```

```swift
// SettingsWindow+General.swift — only reached once updateChecker.isUpdateAvailable is true:
let provenance = await detectUpdateProvenance()
switch provenance {
case .packageManaged(let origin):
  // show aptUpgradeCommand, no install button
case .standaloneDebInstall:
  // show "Install Update…", gated behind a confirmation dialog
case .undetermined(let reason):
  // show reason + a pointer to the public releases page
}
```
