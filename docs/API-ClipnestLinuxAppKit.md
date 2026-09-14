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
- [`LinuxClipboardSelectionReplacer` declines terminal-class targets before any I/O (T-TERMPASTE1)](#linuxclipboardselectionreplacer-declines-terminal-class-targets-before-any-io-t-termpaste1)
- [`LinuxClipboardSelectionReplacer`'s copy-sentinel detection (T-COPYFLAKE1)](#linuxclipboardselectionreplacers-copy-sentinel-detection-t-copyflake1)
- [`GSettingsCustomKeybinding` — the GSettings hotkey floor stayed dead after the Shell extension was disabled (T-HOTKEYFLOOR-GAP1)](#gsettingscustomkeybinding--the-gsettings-hotkey-floor-stayed-dead-after-the-shell-extension-was-disabled-t-hotkeyfloor-gap1)
- [`IBusCommitClient` — the IBus commit-tier live connection (T-IBUS-CLIENT, corrected by T-IBUS-REPLACER)](#ibuscommitclient--the-ibus-commit-tier-live-connection-t-ibus-client-corrected-by-t-ibus-replacer)
- [`LinuxIBusSelectionReplacer` / `LinuxTieredSelectionReplacer` / `IBusCommitPolicy` — the IBus + clipboard composer (T-IBUS-REPLACER)](#linuxibusselectionreplacer--linuxtieredselectionreplacer--ibuscommitpolicy--the-ibus--clipboard-composer-t-ibus-replacer)
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

## `LinuxClipboardSelectionReplacer` declines terminal-class targets before any I/O (T-TERMPASTE1)

`replaceSelection` checks the frontmost app FIRST, before any of the
copy-sentinel/write machinery documented below ever runs:

```swift
let isTerminalTarget =
  TerminalAppRegistry.modifiers(forAppIdentifier: frontmostRef?.bundleID) == [.control, .shift]
guard !isTerminalTarget else {
  return .declinedTerminalTarget   // no suppression, no snapshot, no keystroke
}
```

**Why:** this class's only replace mechanism is Copy-then-Paste with no
explicit delete step — it relies on "paste replaces the OS-level
selection," which is false for terminal emulators, where a mouse-drag
highlight is a cosmetic, copy-only artifact disconnected from the shell's
real cursor. Left unguarded, every expansion in a terminal corrupts the
line into `<keyword><body>` instead of replacing it (this is the SAME
defect macOS's `ClipboardSelectionReplacer` has — confirmed live there,
2/2 trials, Terminal.app — present here by identical construction, per
this task's routing brief). `TerminalAppRegistry` is reused for this check
purely because its identifier vocabulary already exists (WM_CLASS/desktop-
file identifiers), NOT for its usual reason (picking Ctrl+Shift+C/V so
copy/paste functions at all in a terminal) — a positive match here means
"never attempt this transaction," full stop, since chord selection alone
never fixes the missing-delete-step corruption. Once past this gate,
`runTransaction` always uses plain `.control` for both keystrokes — the
Ctrl+Shift chord path is dead for this specific caller and was removed
from it rather than left unreachable.

Sending backspaces first (to erase the highlighted text before pasting)
was considered and rejected — verified against real prior art (espanso,
AutoKey, both checked against their actual source, not marketing docs):
both erase-then-inject only because they track the trigger being TYPED,
keystroke by keystroke, so the backspace count is a known quantity tied to
the real cursor. This class's "keyword" is whatever the user mouse-drag-
highlighted — a quantity never observed being typed, whose position
relative to the real cursor is unknowable in a terminal (the whole reason
this bug exists). Backspacing that many characters would delete that many
WRONG characters at the actual cursor position: silent, wrong-location data
destruction, strictly worse than the visible append it would replace.

**Reachability:** requires a PRE-EXISTING drag selection — the ordinary
flow (type keyword, press the hotkey with nothing selected) already
returns `.noSelection` and beeps, unaffected. Not exercised on the real
GNOME VM for this task (no display attached in that session at the time),
but the decision itself and its "zero clipboard I/O on decline" contract
are covered by `LinuxClipboardSelectionReplacerTests`
(`declinesTerminalTargetBeforeAnyClipboardIO`,
`nonTerminalFrontmostAppStillRunsNormalTransaction`) and were run against a
real aarch64 Ubuntu build on the project's GNOME VM (full `clipnest`
binary + full test target build succeeded; the affected suite plus the
untouched `TerminalAppRegistryTests` were run directly rather than the
whole `ClipnestPlatformLinuxTests` target, to avoid the known pre-existing
GSettings-mutating test elsewhere in that target).

**Known gap — INERT on native Wayland (T-TERMDECLINE-WAYLAND1, found
2026-09-14):** the `frontmostRef` this gate reads comes from
`LinuxFrontmostAppReferenceProvider`, which is X11-only
(`_NET_ACTIVE_WINDOW` + `WM_CLASS`/`_NET_WM_PID`/`_GTK_APPLICATION_ID`).
`WindowIdentityClassifier` already models the honest third state for a
native-Wayland-focused window — `.waylandFocusUnavailable`, "something IS
focused, this backend just cannot see what" — but
`LinuxFrontmostAppReferenceProvider.currentFrontmostAppRef()` collapses that
case (and the "identified but no PID" case) to `nil`, which this decline
check reads as "not a terminal" (`TerminalAppRegistry`'s own contract:
`nil`/unrecognized defaults to "not a terminal," never a positive match).
**Net effect: on a native-Wayland terminal (no XWayland fallback available
for its identity), this decline never fires and the line is still
corrupted into `<keyword><body>`** — exactly the bug this whole gate exists
to prevent, for exactly the session type this branch targets. The decline
IS effective on X11 sessions and on XWayland clients whose properties are
readable. Fixing this requires a product decision (depend on the optional
GNOME Shell extension's `focusProbe`/`ShellFocusedApp`, which already knows
the real focused app on Wayland, vs. decline-on-unknown-identity, which
would refuse expansion in every native-Wayland app whose identity can't be
read, not just terminals) — tracked as `T-TERMDECLINE-WAYLAND1` on the
board, the same tension already blocking `T-CROSSDEVICE-MODIFIER1`. Not
fixed here; documented so nobody mistakes silence for coverage.

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

### Fix attempted (T-MODWAIT-WAYLAND1, 2026-09-14) — one part real, the modifier-release strategy RETRACTED (T-CROSSDEVICE-MODIFIER1)

**This section used to read as a completed fix. It wasn't one.** Two
independent measurements taken the same day (`T-CROSSDEVICE-MODIFIER1`,
below) proved the modifier-release strategy this section originally
described does not stop the merge it was built for. The section is
rewritten below in the past tense, describing what was attempted, what was
measured, and what is actually true now.

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

**What was tried**: `ModifierReleaseWaiter`'s read-then-wait shape cannot be
salvaged for Wayland — there is no reader this protocol's `currentModifierMask()`
shape could return that is trustworthy for a native-Wayland-focused window,
compositor-companion or not (see `ModifierMaskReading`'s doc comment). So
instead of trying to answer "is a modifier held," the uinput backend was
changed to UNCONDITIONALLY release every tracked modifier keycode (both
left/right variants of Ctrl/Shift/Alt/Super — `LinuxEventCode.allModifierKeycodes`,
verified against the VM's own `/usr/include/linux/input-event-codes.h`, not
assumed) through the same `/dev/uinput` device immediately before posting a
chord, on Wayland sessions only. Both strategies were unified behind one new
seam, `ModifierGuarding`
(`Sources/ClipnestPlatformLinux/Input/ModifierGuarding.swift`):
`WaitForReleaseModifierGuard` (X11, wraps the unchanged
`ModifierReleaseWaiter`) and `ForceReleaseModifierGuard` (Wayland).

**What actually landed and is real, independent of the retraction below**:
`LinuxEventSynthesizerFactory` now branches on `SessionType`, not display
reachability. Before this fix, the factory picked a modifier strategy by
asking "can I open an X display?" — which XWayland answers yes to on a
GNOME Wayland session, so it silently handed a native-Wayland session the
X11 reader, which reports success with an empty modifier mask while
Shift/Super are physically held (see the root cause above). Now the factory
asks the session type directly: `.x11` gets `WaitForReleaseModifierGuard`
(genuinely trustworthy there), `.wayland`/`.unknown` get
`ForceReleaseModifierGuard`. **This part is the real, kept win from this
commit** — a wrong reading is no longer silently trusted just because
XWayland happens to be reachable, regardless of what
`ForceReleaseModifierGuard` itself does or does not fix (see the retraction
below).

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
model, so skipping the restore keeps that path correct. Unit-tested
exact-sequence assertions for the release mechanism live in
`Tests/ClipnestPlatformLinuxTests/InputModifierGuardingTests.swift`.

**RETRACTED (T-CROSSDEVICE-MODIFIER1, measured 2026-09-14): `ForceReleaseModifierGuard`
does not fix the merge it was built to fix.** This section previously
claimed the injected chord "can no longer merge with a stale Shift/Super"
and that the result was "strictly better than the prior 100%-merge-failure
state." Both claims are false. Two independent measurements say so:

1. A before/after run of the full production binary against its own parent
   commit showed the user-visible failure rate does not move on 7 of 8
   conditions from the table above, with overlapping confidence intervals on
   the 8th (see the board's `T-MODWAIT-WAYLAND1` REJECT entry).
2. A Clipnest-free experiment with two independent virtual keyboards and a
   GTK4 key-event logger reading `Gdk.ModifierType` directly proved the
   mechanism: Mutter tracks modifier state **per originating device**, so a
   key-up posted from Clipnest's own uinput device cannot clear a modifier
   the user's physical keyboard is still asserting.

   | condition | result |
   | --- | --- |
   | positive control (B alone, Ctrl+C) | 8/8 clean |
   | baseline, A holds Shift | 8/8 merged |
   | force-release, A holds Shift, B releases it | 15/15 STILL MERGED |
   | baseline, A holds Super | 8/8 merged |
   | force-release, Super | 8/8 STILL MERGED |
   | phantom release (nobody holding) | 6/6 clean, zero events emitted |

The injected chord can still merge with a stale Shift/Super held on the
user's physical keyboard. `ForceReleaseModifierGuard` is kept in the tree
because it is harmless (releasing an unpressed key is a documented evdev
no-op — the phantom-release row above) and because the `ModifierGuarding`
seam is the right shape for a strategy that CAN work — **not because it
currently works.** The only remaining candidate is the GNOME Shell
extension's Clutter seat state (the compositor is the one party that knows
the true aggregate modifier state), which would make correct paste depend
on a component this project documents as optional — a product decision,
tracked as `T-CROSSDEVICE-MODIFIER1` on the board, not resolved here. See
`Sources/ClipnestPlatformLinux/Input/ModifierGuarding.swift`'s
`ForceReleaseModifierGuard` doc comment for the same measurements, kept in
sync with this section.

### Diagnostics surface added for this investigation

| symbol | module | what it answers |
| --- | --- | --- |
| `LinuxPasteboard.selectionOwnerWindowID` / `X11SelectionConnecting.selectionOwnerWindowID()` | `ClipnestPlatformLinux` | which X11 window owns CLIPBOARD right now (`XGetSelectionOwner`). On a GNOME Wayland session this is always mutter's own selection-bridge window, for every client — so it cannot identify WHICH app answered a copy, and that is itself worth knowing before anyone designs around it. |
| `LinuxClipboardSelectionReplacer.focusProbe` | `ClipnestLinuxAppKit` | optional hook, wired by `LinuxAppLifecycle.wireShellHelper`, returning the compositor's own focused-window identity at the instant of the synthesized Ctrl+C. |
| `ShellHelperClient.getFocusedApp()` / `ShellFocusedApp` | `ClipnestLinuxAppKit` | decoded `GetFocusedApp()` reply (app id, human-readable app name, WM class, pid, mutter window serial, x11-vs-wayland client type). This is `GetFocusedApp`'s FIRST Swift caller — the method had been implemented, tested and shipped in the extension with no reader at all, one of the dead paths `coding-standards.md` lists. `logDescription` (N3 fix) now renders every field including `name` — it was decoded and stored but left out of this rendering with no other reader anywhere, the same dead-path shape one level down. |
| `GSettingsCustomKeybinding`'s `gsettings floor install: … bindingChanged=<bool>` log line | `ClipnestLinuxAppKit` | Swift's OWN diagnostic view of whether the stored accelerator differed from last time. As of the T-HOTKEYFLOOR-GAP1 fix below this **no longer gates whether a grab is attempted** — `install` always forces a fresh grab attempt regardless of this value, precisely because `bindingChanged=false` was shown to NOT mean "gsd's grab is fine." Kept for diagnostics only; see the dedicated section below for the full mechanism and fix. |

Every field these emit is metadata — booleans, counts, elapsed ms, window
ids, WM classes. No log line added here can carry clipboard or selection
content; `isSentinelOnClipboard` reads the clipboard string but collapses it
to a `Bool` before it can reach a log line.

## `GSettingsCustomKeybinding` — the GSettings hotkey floor stayed dead after the Shell extension was disabled (T-HOTKEYFLOOR-GAP1)

**Bug report**: after `gnome-extensions disable clipnest@clipnest.app`, both
global hotkeys (`<Super><Shift>v` toggle, `<Super><Shift>e` expand) were
observed dead on some retries while `dconf dump` showed the GSettings
custom-keybinding floor values present and correct, and Clipnest's own state
had already reconciled (`hotkey backend resolved: gsettingsFloor (was
shellExtensionKeybinding)`). This directly contradicted
`LinuxAppLifecycle.resolveAndApplyHotkeyBackend`'s own doc-comment guarantee
that a user is never left with a dead hotkey and no fallback.

### Root cause (measured live against a real `gnome-shell`/`gsd-media-keys`, not inferred from source)

`gnome-settings-daemon`'s media-keys plugin only calls
`org.gnome.Shell.GrabAccelerators` to (re-)acquire a custom keybinding's
accelerator in reaction to a **genuine GSettings value change** on that
binding's `binding` key — confirmed by capturing the real session bus with
`dbus-monitor --session` while writing the key both ways: a value-identical
`gsettings set` produced zero `GrabAccelerators` calls; a genuinely different
value produced one within ~90 ms. `GSettingsCustomKeybinding.install` was
writing the SAME accelerator on every steady-state reconcile (the floor is
(re)installed on every hotkey-backend reconcile, not just once — see
`LinuxAppLifecycle.resolveAndApplyHotkeyBackend`), so gsd never even
attempted a re-grab after the Shell extension (which had been winning the
single exclusive Mutter grab for that accelerator via its own
`Main.wm.addKeybinding`, `extension/src/core/keybindings.js`) released it.

This is a **permanent gap, not a narrow timing race**: a failure-rate-vs-delay
sweep (12 trials/bucket, 72 trials total) pressing the hotkey at 0.0 / 0.2 /
0.5 / 1.0 / 2.0 / 5.0 seconds after disabling the extension measured **0/72
successes at every single delay** once the floor's Mutter grab had never been
validly acquired — waiting longer never helped, because gsd was never asked
to retry. The grab can also fail to be acquired in the FIRST place: if the
Shell extension already holds the same accelerator at the moment gsd's one
genuine attempt fires, that attempt loses the race, confirmed by
`GrabAccelerators`' own return value — `0` (Shell's documented failure
sentinel) when contended, a real nonzero action id (e.g. `766`) when
uncontested.

### Fix

`GSettingsCustomKeybinding.install` now writes the `binding` key through
`bindingWriteSequence(for:)` — a small pure, unit-tested helper
(`Tests/ClipnestPlatformLinuxTests/AppGSettingsCustomKeybindingTests.swift`)
that returns `["", binding]` for any non-empty accelerator (`""` is the
schema's own "no binding" convention, the same one GNOME Settings' Keyboard
panel uses to clear a shortcut — not an invented sentinel). Writing the empty
value first, then the real value, forces a genuine transition on **every**
call, regardless of whether the caller's value matches what was last
installed, so gsd always gets a fresh reason to attempt the grab at exactly
the moment the floor might be the only thing left holding the hotkey. The
diagnostic `bindingChanged` field logged by `install` is unaffected and
remains useful, but no longer gates the fix — see this file's diagnostics
table above.

**Before/after, same measurement**: re-running the identical
disable-then-press sweep against the fixed binary reached **72/72** across
every delay bucket (0.0 through 5.0 s), including the harder case where the
Shell extension held the accelerator immediately before being disabled
(reproduced end to end through the real `onCapabilitiesChanged` reconcile
path, not a simulated write).

**Rejected**: gating the forced write on `previousBinding != binding`. That
comparison is exactly what let this bug ship — it reflects Swift's own
cached value, not whether gsd's Mutter grab is actually live, and using it to
skip the second write would silently reintroduce the gap for every
steady-state reconcile (the common case this floor exists to cover). Also
rejected: simply waiting longer before pressing — the sweep above shows the
window never closes on its own, at any delay tested.

## `IBusCommitClient` — the IBus commit-tier live connection (T-IBUS-CLIENT, corrected by T-IBUS-REPLACER)

`Sources/ClipnestLinuxAppKit/InputMethod/IBusCommitClient.swift`. The live
connection layer the pure protocol layer
([`docs/API-ClipnestPlatformLinux-IBus.md`](API-ClipnestPlatformLinux-IBus.md))
was built for. Performs snippet expansion's tier-2 D-Bus commit (D-IBUS-1..6,
`.claude/project-context.md`): **switch the global IBus engine to ours ->
wait for a receptive widget to answer `SetSurroundingText` -> recover the
selected keyword from it (no synthesized keystroke) -> ask the caller for a
replacement -> delete the keyword + commit the replacement -> switch back**,
with a crash-safety state machine so a mid-transaction crash never leaves the
user on a dead engine.

**Correction (T-IBUS-REPLACER, superseding T-IBUS-CLIENT's original
design):** the gate is `SetSurroundingText`, not `FocusIn`. The client task's
own VM measurement — `FocusIn` arriving ~1ms after `SetGlobalEngine` **even
with no GUI text field focused at all** (a bare SSH session against an idle
desktop) — proves `FocusIn` only confirms "the daemon bound our engine to
SOME input context," never "a receptive text-editable widget is ready."
Gating on `FocusIn` alone would have made the clipboard-tier fall-through
essentially never trigger while reporting the terminal, no-retry
`.committedUnconfirmed` outcome — strictly worse than the bug this feature
exists to fix. The real gate (D-IBUS-5): once `FocusIn` confirms the engine
is bound, the client emits `RequireSurroundingText`; a REAL text-editable
widget answers with a genuine `SetSurroundingText(text, cursor_pos,
anchor_pos)` round trip. That answer's `cursor_pos`/`anchor_pos` ALSO recover
the highlighted keyword with zero synthesized keystrokes — the same
"immune by construction" property that makes this whole tier exist.

```swift
public enum IBusCommitOutcome: Sendable, Equatable {
  case noLiveRecipient       // FocusIn or SetSurroundingText never arrived — fall through
  case noSelection           // SetSurroundingText arrived but cursor_pos == anchor_pos — fall through
  case noMatch               // a real selection was recovered but bodyForSelection found no snippet — TERMINAL
  case committedUnconfirmed  // a real, matched selection — delete+commit issued — TERMINAL, never retry
  case unavailable           // IBus couldn't even be asked — fall through, same as noLiveRecipient
}

public final class IBusCommitClient: @unchecked Sendable {
  public static let defaultCallTimeout: Duration             // .milliseconds(250)
  public static let defaultFocusInTimeout: Duration           // .milliseconds(200)
  public static let defaultSurroundingTextTimeout: Duration   // .milliseconds(200), NOT independently VM-measured — see this constant's own doc comment
  public static let defaultConnectTimeout: Duration           // .seconds(2)

  public init(
    registrationConnection: DBusConnection, callConnection: any DBusCalling,
    store: any KeyValueStore, focusInTimeout: Duration = defaultFocusInTimeout,
    surroundingTextTimeout: Duration = defaultSurroundingTextTimeout,
    callTimeout: Duration = defaultCallTimeout)

  /// Resolves the IBus private-bus address, gates it on the daemon PID
  /// actually being alive (T-IBUS-PIDLIVE), opens BOTH connections, and
  /// calls `start()`. The one entry point a caller needs.
  public static func resolveAndConnect(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: any KeyValueStore,
    connectTimeout: Duration = defaultConnectTimeout,
    callTimeout: Duration = defaultCallTimeout,
    focusInTimeout: Duration = defaultFocusInTimeout,
    surroundingTextTimeout: Duration = defaultSurroundingTextTimeout
  ) -> IBusCommitClient?

  @discardableResult public func start() -> Bool   // reconcile -> register -> reader thread

  /// Recovers the selection from `SetSurroundingText`, asks `bodyForSelection`
  /// for a replacement, and on a match delete+commits it. Replaces the
  /// pre-T-IBUS-REPLACER `commit(replacingKeyword:withReplacementText:)`,
  /// which required the caller to already know the keyword — impossible
  /// once the keyword itself comes from the surrounding-text answer, not a
  /// synthesized copy.
  public func replaceSelection(bodyForSelection: sending @escaping (String) async -> String?) async
    -> IBusCommitOutcome
}
```

**Usage** (`LinuxIBusSelectionReplacer`, below, is the one real caller):

```swift
guard let client = IBusCommitClient.resolveAndConnect(store: keyValueStore) else {
  // IBus unavailable this session — fall through to the next tier.
  return .noSelection
}
switch await client.replaceSelection(bodyForSelection: { selection in
  await snippetStore.findByKeyword(selection)?.body
}) {
case .committedUnconfirmed, .noMatch:
  return mapped   // TERMINAL — do not also try the clipboard tier
case .noLiveRecipient, .noSelection, .unavailable:
  // fall through to the next tier
}
```

### Architecture — two connections, not one (D-IBUS-4)

`registrationConnection` registers our component/engine and is the ONE
connection whose reader thread ever calls `receiveOneMessage` on it — every
inbound `Factory.CreateEngine`/`Engine.*` call arrives and is replied to
here, and the outbound `DeleteSurroundingText`/`CommitText` SIGNALS are also
sent on THIS connection (real ibus-daemon proxies an engine's signals through
whichever connection registered it — emitting from a different connection
would not reach the daemon's routing for this engine at all).
`callConnection` only ever does blocking `SetGlobalEngine`/`GetGlobalEngine`
calls, mirroring `ShellHelperClient.callConnection`'s identical role.

**Verified, not just theorized** — against a real `ibus-daemon` (1.5.29-rc2)
on the project's VM, with a raw two-connection probe mirroring this exact
shape (not libibus's own GI sync-call wrapper, which is a different code
path this app never uses): `RegisterComponent` and `SetGlobalEngine`
(issued on the separate outbound connection) both completed in low
single-digit milliseconds while `CreateEngine`/`Enable`/`FocusIn` were served
concurrently on the registration connection's own independent reader thread
— 3/3 clean runs, zero deadlocks, zero timeouts. `FocusIn` itself arrived
~1ms after `SetGlobalEngine` was issued, 3/3 runs. See
`.claude/logs/senior-dev.md` for the full measurement and the reasoning for
why a single shared connection is unsafe here independent of any libibus
quirk (`DBusConnection.call(_:timeout:)`'s own reader loop discards any
message that isn't the specific reply it's waiting for).

### Crash safety (D-IBUS-3) — `IBusCrashSafetyStateMachine`

Pure, fully unit-tested (`IBusCrashSafetyStateMachineTests.swift`) against a
fake `KeyValueStore` and fake `setGlobalEngine` closures — persists the
previous engine name (under the existing `KeyValueStore` seam
`SettingsStore` already uses, no new dotfile) before ever switching, clears
that marker only after a CONFIRMED restore, and — critically — `start()`
runs `reconcileAtStartup()` **before anything else**, so a process that died
mid-transaction gets force-restored on the very next launch, keyed on this
app's OWN persisted marker, never on `GetGlobalEngine`'s live value (which
the architect's own POC measured reporting unreliably after a crash).

### Wiring D-IBUS-3 to the process lifecycle (T-IBUS-CRASHWIRE)

`IBusCrashSafetyStateMachine` itself only defines the state machine;
`Sources/ClipnestLinuxAppKit/App/{SelfPipe,ProcessSignalShutdown}.swift` and
`Sources/ClipnestLinuxAppKit/InputMethod/IBusCrashSafetyReconciler.swift` are
the pieces that actually connect it to real process shutdown — SIGTERM,
SIGINT, and the tray's "Quit" item — none of which existed before this task
(there was no signal handler of any kind anywhere in this codebase).

```swift
// IBusCrashSafetyReconciler — the ONE routine LinuxAppLifecycle.launch()'s
// startup reconciliation, the SIGTERM/SIGINT self-pipe dispatch, AND the
// tray's "Quit" item all call, so all three can never drift apart.
// Deliberately NOT IBusCommitClient.resolveAndConnect()+.start(): opens
// exactly one short-lived connection, only when the marker is genuinely
// pending (the internal IBusCrashSafetyStateMachine.reconcileAtStartup gate
// checks the marker FIRST), and never registers a component/engine or
// leaves a reader thread running.
enum IBusCrashSafetyReconciler {
  static func restoreIfMarkerPresent(
    store: any KeyValueStore,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    connectTimeout: Duration = IBusCommitClient.defaultConnectTimeout,
    callTimeout: Duration = IBusCommitClient.defaultCallTimeout
  )
}

// ProcessSignalShutdown — self-pipe + sigaction(SIGTERM/SIGINT) + a GLib
// IO-watch dispatch. The raw signal handler does exactly ONE thing (write
// one byte to the pipe) — every other coding-standards.md-mandated
// restriction on signal-handler content applies here as it does to a GTK
// signal handler; the actual restore + quit logic runs later, off the GLib
// main loop, via `onShutdownSignal`.
enum ProcessSignalShutdown {
  static func install(onShutdownSignal: @escaping @MainActor () -> Void)
}
```

**Call sites, `LinuxAppLifecycle.swift`:**
- `run(arguments:)`, right after `GTKMainActorBridge.install()`:
  `ProcessSignalShutdown.install(onShutdownSignal:)`, whose closure calls the
  shared `restoreIBusEngineBeforeQuit()` helper then
  `ClipnestGTKApplication.quitMainLoop()`.
- `launch(...)`, as the literal FIRST statement — before `LinuxAppEnvironment`
  or any other subsystem is constructed:
  `IBusCrashSafetyReconciler.restoreIfMarkerPresent(store:
  PlatformDefaults.keyValueStore)`.
- `startTray(...)`: `tray.onQuit` now calls the SAME
  `restoreIBusEngineBeforeQuit()` helper before `quitMainLoop()`, so graceful
  quit and signal-triggered quit share one path.

**What this covers, stated plainly, not implied:** SIGTERM and SIGINT — the
signals a process supervisor/systemd stop or Ctrl-C actually send. **SIGKILL
is uncatchable by definition** — no in-process hook can run before a
SIGKILLed process's address space vanishes; the mitigation there is
`launch()`'s startup reconciliation repairing a marker left dangling by ANY
cause on the NEXT launch, plus IBus's own kernel-driven socket-disconnect
detection, neither of which depends on this app doing anything at all.

**Verified live on the real VM daemon** (no Swift toolchain exists on that
VM — same "raw probe mirroring the Swift architecture" precedent
`IBusCommitClient`'s own VM verification already used, not the compiled
Swift binary): a Python harness reproducing this exact algorithm (self-pipe
+ `GLib.io_add_watch` + the marker-file read/write) against the real
`ibus-daemon`, with the crash-safety marker deliberately dirtied to a
DIFFERENT engine than the one currently active —
1. **Startup-reconciliation path**: invoking the restore routine directly
   (no signal involved) changed the real global engine from `xkb:us::eng` to
   the dirtied marker's value (`xkb:us:haw:haw`) and cleared the marker —
   confirmed via `ibus engine` and the settings file before/after.
2. **SIGTERM path**: a real `kill -TERM` sent to a separate process running
   the self-pipe/GLib dispatch loop produced the identical restore (log:
   `self-pipe IO watch fired on the GLib main loop ... SetGlobalEngine(...)
   CONFIRMED, marker cleared`), and the process exited cleanly afterward.

Not literally verified: an actual in-flight `IBusCommitTransaction`
interrupted mid-transaction by a real SIGTERM (that requires
T-IBUS-REPLACER's live wiring into `LinuxAppEnvironment`, built concurrently
with this task) — the marker-dirtying above simulates the EXACT on-disk
state such a crash leaves behind (the mechanism this task builds doesn't
care why the marker is set, only that it is), so this is a faithful proof of
the recovery mechanism, not of the end-to-end feature. Named as the
inference it is, not claimed as the literal scenario.

**Fixed (reviewer REJECT, was: "known integration gap flagged for
T-IBUS-REPLACER's `LinuxAppEnvironment`"):** the paragraph that used to sit
here named a real data-loss bug, not a "theoretical OS-file-level race," and
the reviewer rejected the softer framing — once `LinuxAppEnvironment` exists,
`JSONFileKeyValueStore.persist()` rewrites the WHOLE settings file per
write, so a quit-time write through a second, independently-snapshotted
instance can silently REVERT a concurrent settings write made through
`LinuxAppEnvironment`'s own shared one (the user loses a setting they just
changed, no error — see `SynchronizedKeyValueStoreTests.swift` for both
halves reproduced directly: two independent instances over the same file DO
lose a write; the same shared instance does not, even hit concurrently from
multiple real threads).

`LinuxAppEnvironment` now exposes `restoreIBusEngineIfNeeded()`, which calls
`IBusCrashSafetyReconciler.restoreIfMarkerPresent(store:)` using `self
.keyValueStore` — the SAME `SynchronizedKeyValueStore`-wrapped instance
`settingsStore`/`IBusCommitClient`'s crash-safety writes already share (see
the `LinuxIBusSelectionReplacer` section's "Security/thread-safety note"
below). `LinuxAppLifecycle.restoreIBusEngineBeforeQuit()` — still the ONE
routine both the SIGTERM/SIGINT path and the tray's "Quit" item call, so
that single-routine property is unchanged — now routes through it whenever
`environment` already exists:

```swift
private static func restoreIBusEngineBeforeQuit() {
  if let environment {
    environment.restoreIBusEngineIfNeeded()
  } else {
    // No LinuxAppEnvironment yet (a shutdown signal arriving in the narrow
    // startup window before launch() finishes constructing it) -- no
    // shared synchronized instance exists either, and nothing else in the
    // process could be writing settings concurrently at that point, so a
    // fresh PlatformDefaults.keyValueStore() here is still safe.
    IBusCrashSafetyReconciler.restoreIfMarkerPresent(store: PlatformDefaults.keyValueStore)
  }
}
```

`launch()`'s own STARTUP reconciliation call is deliberately left as-is,
keeping its own fresh `PlatformDefaults.keyValueStore()` instance — it runs
before `LinuxAppEnvironment` (and therefore `keyValueStore`) exists at all,
so the hazard above genuinely does not exist yet at that point (provably
sequential: this environment's `init` — the only other writer — hasn't
started). The two call sites are deliberately asymmetric; both source files'
own doc comments say so explicitly, so a future reader doesn't "fix" one to
match the other and reintroduce the bug.

### Confirmability (D-IBUS-6) and the corrected gate (D-IBUS-5)

`CommitText`/`DeleteSurroundingText` are fire-and-forget signals with no
ack. The gate proving a receptive recipient exists is `SetSurroundingText`
arriving within `surroundingTextTimeout` — NOT `FocusIn` (see this section's
parent for the full correction and the VM measurement that drove it:
`FocusIn` arrived even with no specific GUI text field focused, confirming
only "the daemon bound our engine to SOME context," not "ready to accept a
commit"). Because a delete+commit is only ever issued once
`SetSurroundingText` has answered, the outcome past that gate is
`.committedUnconfirmed`, never `.replaced` (`CommitText`/
`DeleteSurroundingText` still have no ack), and it is TERMINAL: retrying via
another tier after a real commit reached a live recipient risks a double
insert, strictly worse than the status quo bug this feature exists to fix.
`.noMatch` (a real, recovered selection with no snippet match) is ALSO
terminal for the same "the keyword is real" reason
`SnippetExpander`'s Accessibility tier already applies.

### `unicodeScalarCount(of:)`, `selectedText(in:cursorPos:anchorPos:)`, `deleteOffsetAndCount(cursorPos:anchorPos:)` — the delete-count/selection-recovery units

`DeleteSurroundingText(offsetFromCursor:characterCount:)` takes caller-
supplied integers with no type-level enforcement of their unit — the real
deletion arithmetic in upstream `ibus_engine_delete_surrounding_text`
indexes a UCS-4 array, i.e. Unicode SCALARS, never Swift's `String.count`
(grapheme clusters) or `.utf16.count` (surrogate-pair-sensitive). Same unit
for `SetSurroundingText`'s own `cursor_pos`/`anchor_pos` (confirmed against
`ibusimcontext.c`'s `g_utf8_strlen` conversion — see
`docs/API-ClipnestPlatformLinux-IBus.md`). Three pure, unit-tested helpers
on `IBusCommitClient` (internal, exercised directly by
`IBusCommitClientTests.swift`) own this arithmetic so it lives in exactly
one place:

```swift
static func unicodeScalarCount(of text: String) -> UInt32
static func selectedText(in text: String, cursorPos: UInt32, anchorPos: UInt32) -> String?
static func deleteOffsetAndCount(cursorPos: UInt32, anchorPos: UInt32)
  -> (offsetFromCursor: Int32, characterCount: UInt32)
```

`selectedText` recovers the highlighted substring by slicing `text
.unicodeScalars` at `[min(cursorPos, anchorPos), max(cursorPos, anchorPos))`
— `nil` (not the empty string) when `cursorPos == anchorPos` (nothing
selected) or either offset is out of range (a malformed/stale snapshot).
`deleteOffsetAndCount` covers BOTH selection directions: cursor after the
anchor (the common drag-then-release case) gives a NEGATIVE offset reaching
back to the anchor; cursor before the anchor gives offset `0` and the count
reaches forward. Every test exercises a combining accent PLUS a non-BMP
emoji specifically (never ASCII alone), since an ASCII-only fixture cannot
distinguish grapheme, UTF-16, and scalar indexing (the exact D95/T-ATSPI1
failure shape this codebase has already shipped once).

### Cross-module visibility (T-IBUS-CLIENT widening)

`IBusCommitClient` lives in `ClipnestLinuxAppKit`; the pure protocol layer
it drives lives in `ClipnestPlatformLinux`. Symbols widened from `internal`
to `public` to make that possible (each carries its own "T-IBUS-CLIENT"
doc-comment note at the widening site):
`IBusPath.engine(id:)`; `IBusCapabilities`/`IBusText` (full types, including
their static members/inits); `IBusRequests.registerComponent`/
`.setGlobalEngine`/`.getGlobalEngine`/`.commitText`/`.deleteSurroundingText`
plus `IBusComponentDescriptor`/`IBusEngineDescriptor` (full types); `IBusResponses
.isSuccessReply`/`.parseGetGlobalEngineReply`; `IBusInboundRequest` (full
enum + `.decode`); `IBusEngineDispatcher` (full class, `init`, `handle`,
every `on...` closure property). **Also widened (T-IBUS-REPLACER):**
`IBusRequests.requireSurroundingText(objectPath:serial:)` —
`IBusCommitClient` emits it directly, once `FocusIn` confirms the engine is
bound, as the corrected gate's own trigger. Everything else in that module
(`IBusEngineReplies`, `parseCurrentInputContextReply`, `parseIBusText`,
`currentInputContext`, `serializedText`) stays internal — nothing outside
`ClipnestPlatformLinux` needs it yet.

### T-IBUS-PIDLIVE — closed by this task

`IBusAddressResolution` (`ClipnestPlatformLinux`) deliberately omitted the
live-process liveness check upstream `ibus_get_address()` performs (a stale
socket-address file after an `ibus-daemon` restart can point at a dead
daemon). `IBusAddressResolution.resolveWithDaemonPID(environment:readFile:)`
now pairs the resolved address with the SAME file's `IBUS_DAEMON_PID=` line
(still pure — no syscall); the actual `kill(pid, 0)` liveness syscall
(Linux/Glibc only) lives in `IBusDaemonLiveness.isDaemonProcessAlive(pid:)`
(`IBusDaemonLiveness.swift`), called by both `IBusCommitClient
.resolveAndConnect` and `IBusCrashSafetyReconciler.restoreIfMarkerPresent` to
discard a stale address before ever dialing it. The two call sites used to
carry a deliberate, disclosed duplicate copy of this one-line helper each
(concurrent edits to `IBusCommitClient.swift`/`IBusCrashSafetyReconciler.swift`
by two tasks in the same session made a shared call unsafe until both
landed) — folded into this one shared helper once they had (reviewer
non-blocking DRY finding).

## `LinuxIBusSelectionReplacer` / `LinuxTieredSelectionReplacer` / `IBusCommitPolicy` — the IBus + clipboard composer (T-IBUS-REPLACER)

`Sources/ClipnestLinuxAppKit/Clipboard/{LinuxIBusSelectionReplacer,LinuxTieredSelectionReplacer,IBusCommitPolicy}.swift`.
The composing layer D-IBUS-1 calls for: a Linux-only `SelectionReplacing`
composer that tries the IBus commit tier first and falls back to the
existing clipboard copy/paste tier, WITHOUT touching `ClipnestCore`'s
`SnippetExpander` (it still holds exactly one `clipboardReplacer` and has
no idea this composition exists).

```swift
// IBusCommitPolicy — per-app eligibility, mirroring TerminalAppRegistry's
// shape but inverted (exclude list, not include list): eligible by
// default. Deliberately EMPTY — the Electron/Chromium POC found no app
// class needing exclusion, and VTE terminals are the case this tier is
// UNIQUELY good at (see the type's own doc comment for why it must never
// grow a terminal-decline check of its own).
public enum IBusCommitPolicy {
  public static let excludedIdentifiers: Set<String>   // = []
  public static func isEligible(appIdentifier identifier: String?) -> Bool
}

// LinuxIBusSelectionReplacer — drives IBusCommitClient (via the internal
// IBusReplacing seam, for testability), runs the policy gate BEFORE any
// IBus I/O, and maps IBusCommitOutcome onto SelectionReplaceResult — the
// ONE place that mapping happens.
public final class LinuxIBusSelectionReplacer: SelectionReplacing { }

// LinuxTieredSelectionReplacer — the ONE SelectionReplacing LinuxAppEnvironment
// hands SnippetExpander as clipboardReplacer.
public final class LinuxTieredSelectionReplacer: SelectionReplacing {
  public init(ibusReplacer: any SelectionReplacing, clipboardReplacer: any SelectionReplacing)
}
```

**Fall-through table (D-IBUS-1)**, implemented in
`LinuxTieredSelectionReplacer.isTerminal(_:)`:
- IBus -> `.noSelection` (covers `IBusCommitOutcome.unavailable`/
  `.noLiveRecipient`/`.noSelection` AND a policy-excluded target, per
  `LinuxIBusSelectionReplacer.map(_:)`) -> fall through to the clipboard
  tier, exactly as `SnippetExpander` already falls AT-SPI -> clipboard.
- IBus -> `.committedUnconfirmed` / `.noMatch` (and defensively `.replaced`,
  though IBus never actually produces it) -> **TERMINAL**, returned as-is.
  Never also tries the clipboard tier: retrying after a real IBus commit
  reached a live recipient risks a genuine DOUBLE INSERT.

**Degradation** (no `ibus-daemon`, unresolvable address, or connect
failure): `LinuxAppEnvironment.init` never constructs a real
`LinuxIBusSelectionReplacer` in that case — it passes `NullIBusSelectionReplacer`
(private to that file), which always returns `.noSelection` with zero I/O,
the same graceful-nil convention `makeSelectedTextAccessing()` already
uses for AT-SPI.

**Security/thread-safety note (T-IBUS-REPLACER review pass):**
`LinuxAppEnvironment.init` shares ONE `KeyValueStore` instance between
`SettingsStore` (`@MainActor`) and `IBusCrashSafetyStateMachine`'s
persisted-marker seam (reachable from `IBusCommitClient`'s nonisolated
background work — real blocking `NSCondition.wait()` calls happen there,
which must never block the GTK main thread). `JSONFileKeyValueStore`'s own
thread safety otherwise rests entirely on "every caller is
`@MainActor`-isolated" — sharing it as-is would have reintroduced a real,
unsynchronized data race the moment both callers were live simultaneously.
`SynchronizedKeyValueStore` (`LinuxAppEnvironment.swift`; `internal`, not
`private` — widened so `SynchronizedKeyValueStoreTests.swift` can construct
it directly, since `LinuxAppEnvironment.init` itself cannot be built in a
unit test) wraps it in a `Mutex` so every access from either caller
serializes, closing the race without touching `IBusCrashSafetyStateMachine`'s
own pure/synchronous contract or `SettingsStore`'s. `LinuxAppEnvironment`
also holds this instance as `self.keyValueStore` (not just an `init` local)
so `restoreIBusEngineIfNeeded()` — see "Wiring D-IBUS-3 to the process
lifecycle" above — can route the quit-time IBus crash-safety restore through
the exact same instance too, closing the quit-time data-loss bug documented
there.

**Why the wrapper alone isn't the whole fix:** `Mutex` only protects
concurrent access to ONE instance's own in-memory `storage` — two SEPARATE
`SynchronizedKeyValueStore`s (or two raw `JSONFileKeyValueStore`s) each
wrapping a fresh load of the same on-disk file are still unsafe together,
since each holds its own snapshot and whichever persists last silently
wins. The actual fix is sharing ONE instance across every writer in the
process, the wrapper only makes that one shared instance safe to hit from
multiple threads at once.

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
