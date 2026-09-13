#!/usr/bin/env bash
# Automated Shell 45+ (Ubuntu 24.04 noble, GNOME Shell 46) regression gate for
# the extension's ESM variant -- T-EXT-ESM-BROKEN1's test-gap fix.
#
# The jammy leg next to this file (`Dockerfile` + README.md) only documents
# manual copy/paste steps against GNOME Shell 42, which only ever exercises
# `extension/dist/legacy` -- exactly why a real ESM parse break
# (`SyntaxError: ambiguous indirect export`, see extension/build.sh's header
# comment) shipped for the extension's entire history without ever failing a
# test. This script is a real, scriptable, exit-code-driven gate for the
# `esm` variant so a future regression fails CI instead of shipping:
#   0   PASS -- clipnest@clipnest.app (esm) reached extension state ENABLED
#       ("ACTIVE" in `gnome-extensions info`'s own wording) with no load
#       error and no JS ERROR in the session's journal.
#   1   FAIL -- printed the reason (state + the extension's own reported
#       error string, or a JS ERROR line).
#   2   infra problem before the assertion could even run (Docker missing,
#       image build failed, the session never came up, etc).
#
# Verified as a real gate, not just plumbing that always passes: run once
# against the ORIGINAL (pre-fix) zero-export `extension/src/core/*.js`
# copied verbatim into the esm bundle, this reproduces the exact live-VM
# failure --
#   state: <3.0>, error: <'SyntaxError: ambiguous indirect export:
#   ClipboardWatcher @ file:///.../extension.js:3:9'>
# -- then, with `extension/build.sh`'s generated `export { ... };` block
# restored, the same sequence reaches state: <1.0>, error: <''>.
#
# Design notes (each earned by an actual failure while bringing this up):
#   - Does NOT install the `clipnest` .deb like the jammy leg does --
#     building the Swift app is orthogonal to the defect class this leg
#     guards against (a JS-parse-level break in the shell extension itself),
#     and skipping it keeps this leg fast enough to run on every change to
#     `extension/`. See Dockerfile.noble's header comment for what it
#     installs instead (the extension bundle + compiled GSettings schemas).
#   - Enables the extension via `gsettings set org.gnome.shell
#     enabled-extensions` directly, NOT the `gnome-extensions enable` CLI.
#     That CLI is, on Shell 45+, a thin wrapper that (a) writes exactly this
#     same GSettings key -- see this directory's README.md, which already
#     documents this -- and (b) for `list`/`info`, D-Bus-activates a
#     separate, GTK-based `org.gnome.Shell.Extensions` app that needs
#     DISPLAY/HOME threaded all the way into dbus-daemon's OWN activation
#     environment (`dbus-update-activation-environment`, not just the
#     `docker exec` environment) to even start, and independently failed to
#     see a just-installed extension in this harness regardless -- a real
#     but SEPARATE rough edge in that standalone app's own extension
#     scan, unrelated to the ESM defect this leg exists to catch. Skipping
#     it entirely removes that whole fragile dependency.
#   - Asserts via a DIRECT `gdbus call` to `org.gnome.Shell`'s own
#     `/org/gnome/Shell` object (`org.gnome.Shell.Extensions.GetExtensionInfo`)
#     -- the real, running compositor process, already verified to export
#     this interface -- rather than through the same CLI-and-helper-app path
#     that requires the activation-environment plumbing above. This mirrors
#     how `packaging/linux/gnome-shell-test/probe_shell_helper.py` etc.
#     already talk to the shell for the jammy leg: call the real D-Bus
#     object directly, don't go through a wrapper that adds its own
#     failure modes.
#
# Usage: packaging/linux/gnome-shell-test/run-noble-esm-test.sh
# Requires: docker, with --privileged + host cgroup support (verified working
# on Docker Desktop for Mac and native Linux Docker -- see this directory's
# README.md "Findings" section for the underlying systemd-in-Docker approach
# this script automates; that section documents WHY each flag below is
# needed, this script only encodes HOW).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
IMAGE="clipnest-gnome-shell-test-noble:latest"
CONTAINER="clipnest-gnome-shell-test-noble"
UNIT="gtester-gnome"
UUID="clipnest@clipnest.app"

log() { echo "[run-noble-esm-test] $*"; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL(infra): docker not found" >&2
  exit 2
fi

log "regenerating extension/dist from source (debian/rules' own policy: never trust a stale checkout)"
"$REPO_ROOT/extension/build.sh"

log "building $IMAGE (build context: repo root, needs extension/dist + packaging/linux/schemas)"
if ! docker build -f "$HERE/Dockerfile.noble" -t "$IMAGE" "$REPO_ROOT"; then
  echo "FAIL(infra): docker build failed" >&2
  exit 2
fi

cleanup  # drop any stale container from a previous interrupted run
log "starting the noble container (systemd as PID 1)"
docker run -d --name "$CONTAINER" \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  "$IMAGE" >/dev/null

log "creating the non-root test user (gnome-shell refuses to run as root)"
docker exec "$CONTAINER" bash -c 'useradd -m -s /bin/bash gtester'
# Unlike the jammy leg's `ubuntu:22.04` base (no pre-existing regular user, so
# `useradd` naturally lands on uid 1000), `ubuntu:24.04` cloud images ship a
# default `ubuntu` user already sitting on uid 1000 -- `gtester` lands on
# whatever uid is actually free (1001 seen in practice). Hardcoding 1000
# throughout (as the manual jammy README does) then silently targets the
# WRONG user's `/run/user/<uid>` for the rest of this script -- `gtester`
# has no access to it, which surfaced as `dconf-CRITICAL: unable to create
# directory '/run/user/1000/dconf': Permission denied` the first time this
# was run against noble. Fix: never hardcode it, read the real uid back.
GTESTER_UID="$(docker exec "$CONTAINER" id -u gtester)"
RUNTIME_DIR="/run/user/$GTESTER_UID"
log "gtester uid=$GTESTER_UID -> $RUNTIME_DIR"
docker exec "$CONTAINER" bash -c "mkdir -p '$RUNTIME_DIR' && chown gtester:gtester '$RUNTIME_DIR' && chmod 700 '$RUNTIME_DIR'"
docker cp "$HERE/session-script.sh" "$CONTAINER":/usr/local/bin/gnome-test-session.sh
docker exec "$CONTAINER" chmod +x /usr/local/bin/gnome-test-session.sh

log "launching gnome-shell as a real, typed logind session (retrying -- logind can take a moment after container start)"
launched=0
for _attempt in $(seq 1 10); do
  if docker exec "$CONTAINER" bash -c "
    systemd-run --uid=$GTESTER_UID --gid=$GTESTER_UID \
      -p PAMName=login \
      -p 'Environment=XDG_SESSION_TYPE=x11' \
      -p 'Environment=XDG_SESSION_CLASS=user' \
      -p 'Environment=XDG_SESSION_DESKTOP=gnome' \
      --unit=$UNIT --collect \
      /usr/local/bin/gnome-test-session.sh
  " 2>/dev/null; then
    launched=1
    break
  fi
  sleep 1
done
if [[ "$launched" -ne 1 ]]; then
  echo "FAIL(infra): systemd-run never accepted the gnome-shell session (logind not up?)" >&2
  exit 2
fi
sleep 8

log "installing the esm variant per-user (mirrors the app's own per-user install path, no sudo/.deb involved)"
docker exec -u gtester -e HOME=/home/gtester "$CONTAINER" bash -c "
  mkdir -p ~/.local/share/gnome-shell/extensions
  cp -r /usr/share/clipnest/gnome-shell-extension/esm \
        ~/.local/share/gnome-shell/extensions/$UUID
"
log "enabling via the GSettings key directly (see header comment for why not the gnome-extensions CLI)"
docker exec -u gtester -e HOME=/home/gtester -e XDG_RUNTIME_DIR="$RUNTIME_DIR" \
  "$CONTAINER" gsettings set org.gnome.shell enabled-extensions "['$UUID']"

log "restarting the session (a brand-new extension UUID is only scanned at Shell startup -- see this directory's README.md Troubleshooting section)"
docker exec "$CONTAINER" systemctl restart "$UNIT.service"
sleep 10

log "asserting extension state via a direct D-Bus call to the real, running org.gnome.Shell"
INFO="$(docker exec -u gtester -e HOME=/home/gtester -e XDG_RUNTIME_DIR="$RUNTIME_DIR" \
  "$CONTAINER" gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
  --method org.gnome.Shell.Extensions.GetExtensionInfo "$UUID" 2>&1 || true)"
echo "--- GetExtensionInfo($UUID) ---"
echo "$INFO"
echo "-------------------------------"

JS_ERRORS="$(docker exec "$CONTAINER" journalctl --no-pager -u "$UNIT.service" 2>/dev/null \
  | grep -i "JS ERROR" || true)"

# GNOME's ExtensionState enum (js/misc/extensionUtils.js): ENABLED=1,
# DISABLED=2, ERROR=3, OUT_OF_DATE=4, DOWNLOADING=5, INITIALIZED=6,
# UNINSTALLED=99. `gnome-extensions info`'s human-readable "State: ACTIVE"
# is ENABLED (1); "State: ERROR" is 3. Verified directly: the pre-fix
# zero-export core files reproduce `state: <3.0>` with the EXACT live-VM
# error text quoted in this script's header comment; the fixed build
# reaches `state: <1.0>`, `error: <''>`.
pass=1
if ! grep -q "'state': <1\.0>" <<<"$INFO"; then
  echo "FAIL: $UUID (esm) is not in state ENABLED/ACTIVE (state 1)"
  pass=0
fi
if grep -qE "'error': <'[^']+'>" <<<"$INFO"; then
  echo "FAIL: $UUID reports a non-empty error:"
  grep -oE "'error': <'[^']*'>" <<<"$INFO"
  pass=0
fi
if [[ -n "$JS_ERRORS" ]]; then
  echo "FAIL: journal shows a JS ERROR:"
  echo "$JS_ERRORS"
  pass=0
fi

if [[ "$pass" -eq 1 ]]; then
  log "PASS: $UUID (esm variant) is state ENABLED/ACTIVE on GNOME Shell 46 / Ubuntu 24.04, no error, no JS ERROR"
  exit 0
fi
exit 1
