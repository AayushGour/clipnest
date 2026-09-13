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
- [`LinuxClipboardSelectionReplacer`'s copy-sentinel detection (T-COPYFLAKE1)](#linuxclipboardselectionreplacers-copy-sentinel-detection-t-copyflake1)
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

## `LinuxClipboardSelectionReplacer`'s copy-sentinel detection (T-COPYFLAKE1)

`Clipboard/LinuxClipboardSelectionReplacer.swift`'s `replaceSelection` writes
a fixed sentinel string to the clipboard immediately before posting the
synthesized Ctrl+C, then waits for the clipboard's CONTENT to differ from it
— rather than waiting for `X11ClipboardConnection.changeSerial` to advance.
Internal to `replaceSelection`, no public API of its own, documented here
because it changes what the class's `.notice` log lines mean (relevant to
anyone reading them) and is exactly the kind of "why, not just what" decision
this doc's sibling section above already covers for the same class's write
path.

**Why:** `changeSerial` only advances on an observed `XFixesSelectionNotify`
event, and confirmed against mutter's own source
(`src/x11/meta-x11-selection.c`, `notify_selection_owner`), that event only
fires when mutter's X11 bridge decides its cached selection-owner OBJECT
identity changed — an event count, not a write count. A redundant/coalesced
re-assertion of ownership that mutter's bridge treats as "no visible owner
change" never fires the event, so the old `changeCount`-based wait would burn
its full ~500ms ceiling and report `.noSelection` even though the target app
genuinely copied something. Modeled on CopyQ's `Scriptable::copy()`
(`src/scriptable/scriptable.cpp`, verified against the real source, not
assumed from documentation): reset the clipboard to a sentinel, synthesize
the copy, then poll the sentinel slot's CONTENT rather than wait for an
event.

- The sentinel is written through the SAME `privilegedTextWriter` /
  `writer.writeString` fallback pair now shared (via the private
  `writeText(_:)` helper, added in this fix's B1 cleanup) by all THREE text
  writes this class makes — the sentinel, the expansion body, and (see B1
  below) the clipboard restore — for the identical reason: `writer
  .writeString` alone silently no-ops from this class's unfocused background
  call site (T-SNIPPET-FF1).
- The sentinel's own landing is confirmed first via the ORIGINAL event-based
  wait (`changeSerial`), logged as `confirmed=...` — this is Clipnest
  confirming its OWN write, which does not carry the same event/write-count
  asymmetry a third-party app's copy does, and is the same mechanism already
  measured reliable for the expansion-body write (T-SHELLHELPER-TIMEOUT1,
  19/19 round trips). The SAME log line also reads the clipboard directly
  (`sentinelReadBack=...`) rather than only inferring from that event.
- **N1 fix:** the copy step's own strategy is decided on `sentinelReadBack`
  (direct content proof), not the event-based `confirmed` value — gating a
  content-comparison decision on an event count would be self-defeating,
  since an event failing to fire despite a real write landing is exactly the
  asymmetry this whole mechanism exists to route around. When
  `sentinelReadBack` is `false` (no Shell extension AND the ordinary writer
  no-ops), the copy step falls back to the original event-based wait — never
  worse than before this fix, since copy detection never depended on
  Clipnest's own write succeeding in the first place.
- `.notice` log line `waitForChange: observedChange=... viaSentinel=...
  sentinelEventConfirmed=...` distinguishes which mechanism produced the
  reported outcome — `viaSentinel=true` means content comparison decided it
  (driven by `sentinelReadBack`), `viaSentinel=false` means the sentinel
  couldn't be read back and the original event-based path ran instead;
  `sentinelEventConfirmed` is kept alongside it purely as a diagnostic (the
  two disagreeing is itself informative, not something to hide).
- **B1 fix (user-facing data loss):** the clipboard-restore write at the end
  of the transaction used to go through `writer.writeString` directly —
  exactly the channel that silently no-ops from this class's call site. Once
  the sentinel above started landing on the clipboard before every
  transaction, a copy that failed to overwrite it (see the root-cause
  section below) meant the `defer`'d restore was the ONLY thing standing
  between the sentinel and the user's clipboard — and that restore could
  itself silently fail the same way, stranding
  `CLIPNEST_COPY_SENTINEL_7f3a1c9e` there with no trace. Fixed by routing the
  restore through the same `writeText(_:)` helper and, since `defer` bodies
  cannot `await`, splitting `replaceSelection` into the transaction proper
  (`runTransaction`, unchanged in spirit) plus an explicit, awaited
  `restoreClipboard` step afterward that confirms the write landed
  (`clipboard restore: ... confirmed=...`) and logs a loud `.error` if it
  didn't. `.file`/`.image`/`.richText` restores have no privileged
  counterpart (`setClipboardText` is plain-text only) and are unaffected —
  the sentinel is always plain text, so those types were never part of this
  regression.
- **Escalation fix / `.copyUnconfirmed`:** the copy step already computed a
  third-state signal (`stillSentinel`, in the failure probe below) that can
  tell "nothing was selected" apart from "something WAS copied and both
  waits missed it," then discarded it, always returning `.noSelection`
  either way — `SnippetExpander`'s `if result != .replaced` had no way to
  tell them apart, mirroring the exact dishonest-success shape
  `.writeUnconfirmed` was added to close one task earlier, on the write
  side. `SelectionReplaceResult.copyUnconfirmed` is the read-side mirror:
  returned when `sentinelReadBack` was true (content comparison genuinely
  ran) yet the failure probe finds the sentinel is NO LONGER there — a
  direct contradiction, not a confident "nothing happened." When
  `sentinelReadBack` was false (the event-based fallback ran instead),
  `stillSentinel` is not meaningful (see N2 below) and the outcome stays
  `.noSelection`, unchanged from before this fix.

**Verification (B3: reconciled with the Root Cause section below — an
earlier draft of this doc left these two accounts contradicting each other,
written before the investigation below had concluded and never revisited
after):** an initial live-VM measurement (real GNOME 46/GNOME Shell
extension active) found the event/write-count asymmetry this sentinel
mechanism targets already highly reliable in that session's environment —
60/60 successful copy-step trials both before and after this fix, split
evenly between byte-identical and varying selected content per trial (95%
Wilson CI [0.94, 1.0] each) — and could not reproduce the originally
reported 71% failure rate (task `T-COPYFLAKE1`) under those controlled,
faithful conditions.

That result held up under further investigation, not against it: as the
"Root cause of the copy-step failure" section immediately below shows, the
sentinel mechanism documented above is correct defensive engineering and was
NEVER what was failing — the actual defect is upstream of it, in
`UInputEventSynthesizer.post`'s modifier-release guard being inert on a
GNOME Wayland session. The sentinel/content-comparison fix is adopted on the
strength of closing a real, source-confirmed asymmetry (matching a proven
industry pattern for the identical problem class); it is NOT the fix for the
reported 71% failure rate, which is diagnosed and measured separately below.
See `.claude/logs/senior-dev.md` for the full writeup.

### Root cause of the copy-step failure (measured 2026-09-13, T-COPYFLAKE1)

The sentinel mechanism above is correct and is NOT what was failing. The
copy step's real defect is upstream of it, in
`UInputEventSynthesizer.post`'s modifier guard:

- Mutter delivers a grabbed global accelerator on key **press**, so when the
  snippet hotkey (`<Super><Shift>E`) fires, the user's Super and Shift are
  still physically down. Clipnest posts its synthesized `Ctrl+C` 3–20 ms
  later, and the kernel merges that injection with the still-held physical
  modifiers — the target app receives `Super+Shift+Ctrl+C` and copies
  nothing.
- `UInputEventSynthesizer.post` already guards against exactly this with
  `ModifierReleaseWaiter`. On a GNOME **Wayland** session the guard is inert:
  the factory builds it with `X11ModifierMaskReader` (XWayland is reachable,
  so the `NullModifierMaskReader` branch is never taken), and
  `XQueryPointer` returns SUCCESS with an empty mask while Shift/Super are
  physically held whenever a native-Wayland window has focus — 8/8 probe
  samples. The waiter therefore reports `.released` immediately and the
  chord goes out.
- The diagnostics added for this investigation make the distinction
  unambiguous. A failed copy now logs `copy failure probe:
  stillSentinel=<bool> sentinelReadBack=<bool> …`: `stillSentinel=true`
  means the clipboard still holds Clipnest's own sentinel, i.e. the target
  never copied and `.noSelection` is the CORRECT verdict; `stillSentinel=
  false` means the content no longer matches what it was compared against —
  a detection bug **only when `sentinelReadBack` (same log line — N2 fix)
  is also `true`**, i.e. content-comparison genuinely ran and still missed
  it (this now returns `SelectionReplaceResult.copyUnconfirmed`, not a
  confident `.noSelection` — see the copy-sentinel section above). When
  `sentinelReadBack` is `false`, `stillSentinel` is not informative on its
  own — the qualifier matters: three earlier incidents in this project
  misattributed the same failure differently because a qualifying fact
  lived far enough from the value it qualified to be read independently.
  Every failure measured in this investigation was `stillSentinel=true`
  with `sentinelReadBack=true`.

Measured effect (real production binary, Firefox urlbar, per-trial data):

| condition | copy-step failures |
| --- | --- |
| CLI trigger, no modifier held | 0/6 — 95% Wilson CI [0.000, 0.390] |
| CLI trigger, Shift held | 6/6 — CI [0.610, 1.000] |
| CLI trigger, Super held | 6/6 — CI [0.610, 1.000] |
| CLI trigger, Super+Shift held | 6/6 — CI [0.610, 1.000] |
| hotkey held 5 ms | 0/8 — CI [0.000, 0.324] |
| hotkey held 30 ms | 6/8 — CI [0.409, 0.929] |
| hotkey held 100 ms | 8/8 — CI [0.676, 1.000] |
| hotkey held 250 ms | 8/8 — CI [0.676, 1.000] |

A human holds a chord for roughly 60–150 ms, so the user-visible rate for
hotkey-triggered snippet expansion on Wayland is at the top of that curve.
The earlier 0/60 result is explained: that harness triggered expansion
through `clipnest --expand-snippet` (no hotkey, no modifiers held), which is
the 0% row of the same table.

### Fix (T-MODWAIT-WAYLAND1, 2026-09-14)

**Independent re-confirmation first, before changing anything**: the
`XQueryPointer` claim above was re-derived from scratch against a fresh,
independently-built compositor session (`gnome-shell --headless
--virtual-monitor`, not the session the original measurement used), a
genuine native-Wayland client (`gnome-text-editor`, confirmed absent from
`xwininfo -root -tree`'s output — proof it never went through XWayland) with
focus, and a raw C `XQueryPointer` probe against a second, independent
uinput virtual keyboard holding Shift/Super/both. Result: **8/8** —
`XQueryPointer` returned `success=1 state=0x0` every single time, matching
the original finding exactly. The premise held.

**Chosen fix**: `ModifierReleaseWaiter`'s read-then-wait shape cannot be
salvaged for Wayland — there is no reader this protocol's `currentModifierMask()`
shape could return that is trustworthy for a native-Wayland-focused window,
compositor-companion or not (see `ModifierMaskReading`'s doc comment). So
instead of trying to answer "is a modifier held," the uinput backend now
UNCONDITIONALLY releases every tracked modifier keycode (both left/right
variants of Ctrl/Shift/Alt/Super — `LinuxEventCode.allModifierKeycodes`,
verified against the VM's own `/usr/include/linux/input-event-codes.h`, not
assumed) through the same `/dev/uinput` device immediately before posting a
chord, on Wayland sessions only. `LinuxEventSynthesizerFactory` now branches
on `SessionType`, not display reachability: `.x11` still gets the original
wait-and-observe strategy (`XQueryPointer` is genuinely trustworthy on a
real X11 session), `.wayland`/`.unknown` get the new force-release strategy.
Both are conformances of a new seam, `ModifierGuarding`
(`Sources/ClipnestPlatformLinux/Input/ModifierGuarding.swift`):
`WaitForReleaseModifierGuard` (X11, wraps the unchanged
`ModifierReleaseWaiter`) and `ForceReleaseModifierGuard` (Wayland).

This mirrors the Windows analog other text-injection tools already ship for
the identical problem — OpenWhispr's `windows-fast-paste.c` `ReleaseModifiers`/
`RestoreModifiers`, confirmed against that project's actual source: it reads
`GetAsyncKeyState` to find exactly which modifiers are truly held, releases
just those via `SendInput`, pastes, then restores them. `ForceReleaseModifierGuard`
deliberately does NOT restore afterward — the entire premise on Wayland is
that no physical-state read like `GetAsyncKeyState` exists (that read being
wrong is the bug), so blindly restoring risks asserting a modifier the user
was never holding (e.g. the CLI-trigger path above, measured at 0/6 failures
specifically because it holds nothing) and leaving it stuck down. Releasing
a key that was never down is a documented no-op in evdev/XKB's key-state
model, so skipping the restore keeps that path correct; the accepted cost
lands only when a modifier WAS genuinely held: a brief window — bounded by
how quickly the user releases the physical key afterward, since their own
release event then reaches the same shared state as a harmless redundant
release — where a different modifier-dependent action could in principle
misfire. That is strictly better than the prior 100%-merge-failure state at
a human-length hold, and strictly safer than a stuck phantom modifier.

**Before/after, same mechanism as the table above** (uinput virtual keyboard
holding the modifier, `XQueryPointer`/copy outcome observed while held):
before the fix, a physically-held Shift/Super rides along into every
uinput-posted chord unconditionally, matching the 6/6–8/8 failure rows
above. After the fix, `ForceReleaseModifierGuard.clearInterferingModifiers()`
clears all eight tracked keycodes before the chord's own modifiers are
asserted, so the injected chord can no longer merge with a stale Shift/Super
— unit-tested exact-sequence assertions live in
`Tests/ClipnestPlatformLinuxTests/InputModifierGuardingTests.swift`. A full
production-binary re-run of every row in the table above (real hotkey grab,
real target app) is manual-verify-only, same as the rest of this module —
disclosed as unverified live if it could not be completed this session; see
`.claude/logs/senior-dev.md` for exactly what was and wasn't re-measured
live.

### Diagnostics surface added for this investigation

| symbol | module | what it answers |
| --- | --- | --- |
| `LinuxPasteboard.selectionOwnerWindowID` / `X11SelectionConnecting.selectionOwnerWindowID()` | `ClipnestPlatformLinux` | which X11 window owns CLIPBOARD right now (`XGetSelectionOwner`). On a GNOME Wayland session this is always mutter's own selection-bridge window, for every client — so it cannot identify WHICH app answered a copy, and that is itself worth knowing before anyone designs around it. |
| `LinuxClipboardSelectionReplacer.focusProbe` | `ClipnestLinuxAppKit` | optional hook, wired by `LinuxAppLifecycle.wireShellHelper`, returning the compositor's own focused-window identity at the instant of the synthesized Ctrl+C. |
| `ShellHelperClient.getFocusedApp()` / `ShellFocusedApp` | `ClipnestLinuxAppKit` | decoded `GetFocusedApp()` reply (app id, human-readable app name, WM class, pid, mutter window serial, x11-vs-wayland client type). This is `GetFocusedApp`'s FIRST Swift caller — the method had been implemented, tested and shipped in the extension with no reader at all, one of the dead paths `coding-standards.md` lists. `logDescription` (N3 fix) now renders every field including `name` — it was decoded and stored but left out of this rendering with no other reader anywhere, the same dead-path shape one level down. |
| `GSettingsCustomKeybinding`'s `gsettings floor install: … bindingChanged=<bool>` log line | `ClipnestLinuxAppKit` | whether the floor re-install actually CHANGED the stored accelerator. gnome-settings-daemon re-grabs on a GSettings `changed` signal, so a value-identical re-write produces no re-grab — "Clipnest wrote the floor" and "gsd holds the grab" are different facts and now read differently. |

Every field these emit is metadata — booleans, counts, elapsed ms, window
ids, WM classes. No log line added here can carry clipboard or selection
content; `isSentinelOnClipboard` reads the clipboard string but collapses it
to a `Bool` before it can reach a log line.

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
