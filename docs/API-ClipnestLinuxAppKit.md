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
- [`ShellHelperClient.setClipboardText(_:)`](#shellhelperclientsetclipboardtext_)
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

## `ShellHelperClient.setClipboardText(_:)`

Added for T-SNIPPET-FF1 (`DBus/ShellHelperClient.swift`). Writes plain text to
the system clipboard via the optional GNOME Shell extension's PRIVILEGED
`Meta.Selection.set_owner` API (`extension/src/core/clipboard.js`'s
`ClipboardWatcher.setClipboard`, over the existing `SetClipboard(mimetype, fd)
-> serial` D-Bus method) instead of GDK's client-side Wayland clipboard write.

```swift
public func setClipboardText(_ text: String) -> Bool
```

**Why this exists, not just what it does:** GDK's Wayland clipboard backend
(`gdk_clipboard_set_text` → `gdk_wayland_device_set_selection`) requires a
FRESH input-event serial from the calling process's own `GdkWaylandSeat`
before it will call `wl_data_device_set_selection` at all — confirmed against
GTK's own Wayland backend source. A background process that never holds a
Clipnest window's keyboard focus (e.g. reacting to a global hotkey) never has
one, and the compositor then SILENTLY drops the request: no error, no `false`
return, nothing. `Meta.Selection.set_owner` is the compositor's own internal
API — no client-side Wayland protocol round trip, hence no serial gate — so
this method works from exactly that unfocused-background context where GDK's
write cannot.

- **Returns `false`** (never throws/crashes) whenever the extension isn't
  installed/active (`ShellHelperCapabilities`'s `.clipboard` capability isn't
  negotiated), the internal pipe write fails, or the underlying `SetClipboard`
  D-Bus call doesn't reply within `ShellHelperClient.defaultClipboardWriteTimeout`
  — callers are expected to fall back to their own ordinary clipboard-write
  path in that case, exactly as `LinuxClipboardSelectionReplacer
  .privilegedTextWriter`'s consumer does (see
  `Clipboard/LinuxClipboardSelectionReplacer.swift`).
- Mimetype is fixed at `text/plain;charset=utf-8` — this method is a
  plain-text convenience only; richer types still go through
  `GTKClipboardWriting`'s existing multi-representation write.
- The Shell extension is optional and per-user-installable, no root needed:
  copy `extension/dist/esm/` (GNOME Shell 45+) or `extension/dist/legacy/`
  (Shell 42–44) to `~/.local/share/gnome-shell/extensions/clipnest@clipnest.app/`
  and `gnome-extensions enable clipnest@clipnest.app` (a session
  logout/login is needed the first time a brand-new extension UUID is added,
  since GNOME Shell only rescans that directory at its own startup — see
  `extension/README.md`).

**T-SHELLHELPER-TIMEOUT1 (timeout + honest failure reporting):**
`setClipboardText`'s underlying `SetClipboard(mimetype, fd) -> serial` D-Bus
call is the one `ShellHelper1` member whose reply waits on real asynchronous
GIO work in the extension (draining the incoming pipe before the compositor
can take clipboard ownership), not an instant synchronous reply like every
other member on this client — so it gets its own, larger timeout rather than
sharing the default:

```swift
public init(
  callConnection: any DBusCalling, signalConnection: DBusConnection?,
  timeout: Duration = ShellHelperClient.defaultTimeout,               // 250ms — every OTHER member
  clipboardWriteTimeout: Duration = ShellHelperClient.defaultClipboardWriteTimeout  // 1000ms — SetClipboard only
)
```

Measured live against a real GNOME 46 VM (19 real, successful round trips
across multiple sessions): 2–70ms, so 1000ms carries >14x headroom. See
`ShellHelperClient.defaultClipboardWriteTimeout`'s doc comment for the full
measurement writeup, including a real, separate bug this task found and
fixed along the way: `ClipnestControlService` (the `callConnection` this
client is wired to in production) never implemented `DBusCalling`'s
fd-attaching overload at all, so `SetClipboard`/`ReadClipboard` silently
never reached the wire — no timeout value could have fixed that; see
`ClipnestControlService.swift`'s own doc comment.

Callers must also not assume "a paste was posted" means "the write
succeeded" — `LinuxClipboardSelectionReplacer.replaceSelection` still
attempts the paste even when this write's propagation couldn't be confirmed
(best effort), but now reports that case as `SelectionReplaceResult
.writeUnconfirmed`, never `.replaced` — see that enum's doc comment.

**Working example:**

```swift
// Composition root (LinuxAppLifecycle.wireShellHelper) — wired once a
// ShellHelperClient exists (strictly after LinuxAppEnvironment.init returns):
environment.clipboardReplacer.privilegedTextWriter = { [weak client] text in
  client?.setClipboardText(text) ?? false
}
```

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
