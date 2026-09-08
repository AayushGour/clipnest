# Real GNOME Shell test environment (systemd + logind + Xvfb in Docker)

**This works.** A privileged container with `systemd` as PID 1 gets you a
real `systemd-logind`, and — with a properly *typed* logind session (see
below) — a real `gnome-shell`/Mutter you can install the Clipnest GNOME
Shell extension into and drive over D-Bus exactly like a real desktop
would. This corrects an earlier conclusion ("GNOME Shell cannot run in
Docker") that was reached with a bare `docker run` (no systemd/logind at
all) and never re-tried with one.

`packaging/linux/vnc/Dockerfile` (the existing X11+VNC smoke-test image)
deliberately does NOT do this — it uses a plain `docker run`, so it cannot
load the Shell extension by construction. This directory is the
extension-capable counterpart: same `clipnest` `.deb`, plus a real
`gnome-shell` 42.9 (Ubuntu 22.04 jammy, matching the `legacy` extension
bundle) under `systemd`.

## Why a plain `docker run` fails, and what fixes it

1. **No `systemd`, no `logind` at all.** `gnome-shell` calls into
   `org.freedesktop.login1` during `ScreenShield` init
   (`loginManager.js`'s `getCurrentSessionProxy()`). With no `logind`
   service on the bus at all, this is where the earlier attempt died.
   Fix: run `/lib/systemd/systemd` as PID 1 in a `--privileged
   --cgroupns=host` container with `/sys/fs/cgroup` bind-mounted `rw`.
   `systemd-logind.service` then starts for real (socket/D-Bus activated),
   `org.freedesktop.login1` appears on the system bus, `loginctl list-seats`
   reports a real `seat0` — all with zero manual configuration.

2. **A `docker exec` shell has no registered logind *session* for its
   user**, even once `logind` itself is running. `gnome-shell` still
   crashes (`this._userProxy.Display is null` — a genuine reproduction of
   "needs a real seat", TypeError in `loginManager.js`) unless the
   user launching it has an actual, *graphical-typed* session. Fix: use
   `systemd-run --uid=<uid> -p PAMName=login -p
   'Environment=XDG_SESSION_TYPE=x11' -p 'Environment=XDG_SESSION_CLASS=user'
   -p 'Environment=XDG_SESSION_DESKTOP=gnome' --unit=<name> --collect
   <script>` — `PAMName=login` makes `systemd` run the payload through
   `pam_systemd`, which registers a real logind session; the three
   `Environment=` overrides make it `type x11; class user` (not the
   default `background`), which is what makes logind promote it to the
   user's *active/display* session (`loginctl user-status` shows `Display:`
   populated) — the exact thing `loginManager.js` was reading as `null`.

See `Dockerfile` in this directory for the full package list (`systemd
systemd-sysv dbus dbus-x11 gnome-shell gnome-session-bin mutter ...`) and
`session-script.sh` below for the exact boot sequence.

## Rebuilding

```bash
# 1. Build the .deb (reuses the existing build stage)
docker build --target build -t clipnest-build:gnome-test \
  -f packaging/linux/vnc/Dockerfile .
docker create --name extract-deb clipnest-build:gnome-test true
docker cp extract-deb:/out ./deb-out
docker rm -f extract-deb

# 2. Build this image (needs clipnest_*.deb next to this Dockerfile)
cp deb-out/out/clipnest_*.deb packaging/linux/gnome-shell-test/
docker build -f packaging/linux/gnome-shell-test/Dockerfile \
  -t clipnest-gnome-shell-test:1 packaging/linux/gnome-shell-test/
```

## Running

```bash
docker run -d --name clipnest-gnome-shell-test \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  clipnest-gnome-shell-test:1

# create a non-root test user (gnome-shell refuses to run as root)
docker exec clipnest-gnome-shell-test bash -c '
  useradd -m -s /bin/bash gtester
  mkdir -p /run/user/1000 && chown gtester:gtester /run/user/1000 && chmod 700 /run/user/1000
'

# put the boot script (Xvfb + gnome-shell) in place -- see session-script.sh
docker cp session-script.sh clipnest-gnome-shell-test:/usr/local/bin/gnome-test-session.sh
docker exec clipnest-gnome-shell-test chmod +x /usr/local/bin/gnome-test-session.sh

# launch it as a REAL, typed logind session (the part that actually matters)
docker exec clipnest-gnome-shell-test bash -c '
  systemd-run --uid=1000 --gid=1000 \
    -p PAMName=login \
    -p "Environment=XDG_SESSION_TYPE=x11" \
    -p "Environment=XDG_SESSION_CLASS=user" \
    -p "Environment=XDG_SESSION_DESKTOP=gnome" \
    --unit=gtester-gnome --collect \
    /usr/local/bin/gnome-test-session.sh
'
sleep 8
docker exec clipnest-gnome-shell-test loginctl session-status 5   # "type x11; class user"

# install the extension (gnome-extensions install --force <dir> FAILS on a
# real CLI -- it wants a .shell-extension.zip, not a raw directory; see
# Findings below. Manual copy is what actually works):
docker exec -u gtester -e HOME=/home/gtester clipnest-gnome-shell-test bash -c '
  mkdir -p ~/.local/share/gnome-shell/extensions
  cp -r /usr/share/clipnest/gnome-shell-extension/legacy \
        ~/.local/share/gnome-shell/extensions/clipnest@clipnest.app
'
docker exec -u gtester -e HOME=/home/gtester -e XDG_RUNTIME_DIR=/run/user/1000 \
  clipnest-gnome-shell-test gnome-extensions enable clipnest@clipnest.app
# gnome-shell only picks up a BRAND NEW (never-seen) extension directory on
# its own startup scan, not via the live directory-watch path -- restart it:
docker exec clipnest-gnome-shell-test systemctl restart gtester-gnome.service
```

`session-script.sh`:
```bash
#!/bin/bash
set -x
export HOME=/home/gtester
Xvfb :99 -screen 0 1440x900x24 -nolisten tcp &
for i in $(seq 1 50); do DISPLAY=:99 xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
export DISPLAY=:99
exec gnome-shell --x11 --display=:99
```

## Troubleshooting: extension enabled but never appears to the Shell

**Symptom** (hit exactly this way once already — read this before re-deriving
it): after `cp -r` + `gnome-extensions enable`, `gsettings get org.gnome.shell
enabled-extensions` correctly shows `['clipnest@clipnest.app']`, both GSettings
schemas are registered, `metadata.json`'s `shell-version` matches the running
Shell — and yet `gnome-extensions list --enabled` prints nothing,
`org.gnome.Shell.Extensions.GetExtensionInfo` returns an empty `{}`,
`app.clipnest.ShellHelper` never appears on the session bus, and
`journalctl -u <session>.service` shows no extension/JS error at all (because
there IS no error — the Shell simply never tried to load it).

**Cause:** GNOME Shell only discovers a *brand-new* (never-before-seen)
extension UUID while its own process is starting up. The live
`Gio.FileMonitor`-based watch path that reacts to `enabled-extensions`
changing only covers ENABLING/DISABLING an extension the Shell already knows
about (i.e. already scanned once) — it does not retroactively notice a
directory that did not exist the last time the Shell itself started.
`gnome-extensions enable` only ever writes the GSettings key; it does not,
and cannot, make an already-running Shell process rescan
`~/.local/share/gnome-shell/extensions/` for new UUIDs.

**Fix:** the FIRST time a given extension UUID is installed, restart the
gnome-shell process itself (not just `enable` it) — e.g. restart the
`systemd-run` unit from the "Running" section above:
```bash
docker exec clipnest-gnome-shell-test systemctl restart gtester-gnome.service
```
After the restart, re-check with the same `GetExtensionInfo`/`ListNames`
calls shown in "Running" above — `state` should read `1` (ENABLED) and
`app.clipnest.ShellHelper` should be on the bus. Only the FIRST install of a
given UUID needs this; subsequent `enable`/`disable` cycles of an
already-known extension take effect live, no restart needed (confirmed:
`gnome-extensions disable clipnest@clipnest.app` immediately drops
`app.clipnest.ShellHelper` off the bus with no restart, and re-`enable`
brings it back — see the T-P10I/T-P10J re-verification in the Findings
section below).

`probe_shell_helper.py` / `probe_shell_helper2.py` / `probe_readclipboard.py`
/ `probe_setclipboard.py` in this directory are ad-hoc PyGObject scripts
(python3-gi ships with the desktop package set already) that claim
`app.clipnest.Clipnest` themselves — the extension's `_checkSender` only
allows the current owner of that name to call it — so every one of the 11
`app.clipnest.ShellHelper1` methods can be exercised for real without
needing the actual `clipnest` binary running. Copy into the container with
`docker exec -i ... bash -c "cat > /tmp/x.py" < probe_x.py` (plain `docker
cp` intermittently fails to find files under this image's `--tmpfs /tmp`
on Docker Desktop for Mac — pipe the content in instead) and run with
`python3 /tmp/x.py`.

## Findings (2026-09-08 devops investigation)

**GNOME Shell runs for real in Docker Desktop for Mac** given the systemd
session bootstrap above — screenshotted (`Activities`/top-bar/dash all
rendering), `gnome-shell --version` reports real `42.9`, journal shows
"GNOME Shell started" with no crash.

**The extension installs, enables, and exports its D-Bus service with zero
errors** against real Mutter (`GetExtensionInfo` → `state: 1` (ENABLED),
`GetExtensionErrors` → `[]`, `app.clipnest.ShellHelper` owned on the
session bus, `Capabilities` correctly lists all 6: `clipboard, paste,
pointer, placement, focus, hotkeys`).

**All 11 D-Bus methods work and return real, correct data** (verified with
the probe scripts above, waiting out the race noted below first):
`GetPointer` → exact live cursor position; `GetMonitorWorkArea` → correct
`(0, 32, 1440, 868)` for a 1440x900 screen with GNOME's 32px top panel;
`GetClipboardMimeTypes`/`ReadClipboard` → real content set via `xclip`,
round-tripped through the real UNIX fd exactly as the interface doc
specifies; `SetClipboard` → verified with `xclip -o` afterward, matches;
`SendKeyChord` → real XTEST synthesis, returns `true`; `PlaceWindow` /
`FocusAndSendKeyChord` with a bogus token/serial degrade gracefully
(`false` / `"target-lost"`), no crash; `SetClipboardWatch`/
`UnplaceWindow` (void replies) succeed. `GetFocusedApp` returned `{}` in
this minimal session (plausible — no window ever had real WM focus here,
not confirmed as a bug).

**The real hotkey chain fires end-to-end at the Mutter/extension level**:
pressing the default `<Alt><Super>v` (via `xdotool`) makes
`Main.wm.addKeybinding`'s grab fire and the extension emit
`ShortcutActivated('toggle-picker', ts, 700, 400, 0, {})` with the EXACT
live pointer coordinates — confirmed independently with `gdbus monitor`.

**Two real, reproducible bugs found in the app's own D-Bus client code**
(neither is in the extension; both in `Sources/ClipnestLinuxAppKit/`, not
touched by this investigation per its constraints):

1. **`HotkeyBackendResolver` never selects `.shellExtensionKeybinding` on
   a real first launch (5/5 runs, 100% reproducible)** — it falls through
   to `.gsettingsFloor` every time, even with the extension correctly
   installed/enabled/error-free and advertising `hotkeys`. Root cause: a
   real ownership-propagation race. `LinuxAppLifecycle.run` claims
   `app.clipnest.Clipnest` (`startControlService`), then almost
   immediately calls `ShellHelperClient.probeLiveDispatch()` (a live
   `GetPointer` call) as part of `installHotkeys`. The extension's
   `_checkSender` only allows calls from the CURRENT OWNER of
   `app.clipnest.Clipnest`, which it learns asynchronously via
   `Gio.bus_watch_name` — a second, independent D-Bus round trip through a
   different process (`gnome-shell`) that has not necessarily completed
   by the time the app's own probe arrives a few milliseconds later.
   Confirmed directly: the identical `GetPointer` call made from a
   throwaway process that claims `app.clipnest.Clipnest` and then waits
   1.5s before calling succeeds every time (`probe_shell_helper.py`) — the
   access-denied-vs-success is purely a function of how long the caller
   waits after `RequestName`, not anything else. `installHotkeys` has no
   retry/backoff, so this decision is made once, permanently, at startup.
2. **`ShellHelperClient.startWatching()` never subscribes to
   `ShortcutActivated` (or `ClipboardChanged`/`CapabilitiesChanged`)
   at all** — its only `AddMatch` call
   (`DBusStandardRequests.addNameOwnerChangedMatch`) is scoped to
   `type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='app.clipnest.ShellHelper'`,
   which only observes the *ownership* of the ShellHelper name, never a
   signal emitted *by* the ShellHelper object itself. `readLoop` DOES have
   live parsing code for `ShortcutActivated`/`ClipboardChanged`
   (`ShellHelperResponses.parseShortcutActivated`/`parseClipboardChanged`)
   — it is simply never invoked, because the session bus never delivers
   those signals to a connection with no matching rule for them. Confirmed
   live: an independent `gdbus monitor --dest app.clipnest.ShellHelper`
   DID see the real `ShortcutActivated` signal from the real `<Alt><Super>v`
   press; the actual running `clipnest` process's own log showed zero
   evidence of receiving it, and its picker window (`xwininfo`) stayed
   `IsUnMapped` the whole time. This means **even with bug (1) fixed, the
   Shell-extension hotkey path still cannot deliver a hotkey to the app at
   all** — a second, independent, and more fundamental defect. Likely fix
   shape (not applied — out of this investigation's scope): add an
   `AddMatch` rule scoped to
   `type='signal',interface='app.clipnest.ShellHelper1',path='/app/clipnest/ShellHelper'`
   (optionally `,sender=<owner>`) in `startWatching()`, mirroring what
   `StatusNotifierTray.swift` already does correctly for its own signals.

**Not exercised** (environment gap, not a code finding): the
`.gsettingsFloor` custom-keybinding path itself was not verified end-to-end
in this session — that path's actual key grab is normally performed by
`gnome-settings-daemon`'s media-keys plugin, which this minimal test image
does not install/run.

**Also confirmed**: `gnome-extensions install --force <directory>` — the
literal command form referenced elsewhere — fails against the real CLI
(`Error opening file ...: Is a directory`, exit 2). The real
`gnome-extensions install` only accepts a `.shell-extension.zip` bundle
(`gnome-extensions pack` output). Nothing in this repo currently packages
one; the manual `cp -r` into
`~/.local/share/gnome-shell/extensions/<uuid>/` above is what actually
works and is the shape any future install helper should follow.

## Update 2026-09-08: T-P10I and T-P10J are fixed and verified (commit 700c38b)

Both bugs above were fixed in the app (`ShellHelperClient.startWatching()`
now adds a second `AddMatch` for the ShellHelper object's own signals;
`probeLiveDispatch()` is retried on a bounded schedule via
`LinuxAppLifecycle.retryLiveDispatchProbeIfNeeded`). Re-verified against
this same harness — **for the first time in this port's history, a real
`<Alt><Super>v` key press through a real Mutter opens the picker**:

- `HotkeyBackendResolver` now resolves `.shellExtensionKeybinding` on a real
  launch: **15/15 trials** (10 via log-grep, 5 timed: 0.121-0.266s from
  process start to the resolved log line — a small bounded retry window,
  not a hang).
- With the extension disabled (confirmed off the bus first): **5/5 trials**
  still resolve `.gsettingsFloor` cleanly, at 0.122-0.203s — the same order
  of magnitude as the extension-present case, so the retry logic does not
  meaningfully slow the common "no extension" path.
- Clean single-action repro of the real hotkey opening the picker: killed
  `clipnest`, moved the pointer to `(300,600)`, relaunched (resolved
  `shellExtensionKeybinding`), screenshotted the plain desktop (picker
  confirmed `IsUnMapped` via `xwininfo`), sent ONE real `<Alt><Super>v` via
  `xdotool keydown/key/keyup`, re-checked: the picker window was now
  `IsViewable` at exactly `560x420+300+600` (the cursor position), and a
  second screenshot showed the actual rendered picker UI (search bar, type
  filter icons, History/Pinned/Snippets tabs, "No clipboard history yet")
  sitting there.

Two things noticed but deliberately not chased further here (not confirmed
as regressions from either fix — flagged for whoever owns picker UX next):
`PlaceWindow` does not clamp to the monitor's work area (the picker's 420px
height extended past the bottom edge when placed at y=600 on a 900px-tall
screen); a second hotkey press while the picker was already open (during an
earlier, Activities-Overview-obscured test, not the clean repro above) did
not toggle it closed. Full trial data: `.claude/logs/devops.md`; decision
record: `.claude/project-context.md` D91.
