#!/usr/bin/env bash
#
# Clipnest installer — no Homebrew, no Apple Developer ID required.
#
# Why this exists: macOS Gatekeeper only hard-blocks apps carrying the
# `com.apple.quarantine` flag, and that flag is set by the *downloader* (Safari,
# Chrome, Mail, AirDrop…), NOT by the app itself. `curl` does not set it. So
# fetching the release with curl and copying the app into /Applications yields
# an un-quarantined, ad-hoc-signed app that launches WITHOUT the "Apple could
# not verify … is free of malware" dialog — no notarization needed.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
#
# Or download it and run `bash install.sh`.

set -euo pipefail

REPO="AayushGour/clipnest"
APP="Clipnest.app"
DEST="/Applications"

echo "==> Finding the latest Clipnest release…"
# Fetch first, parse second: if `curl` itself fails, `set -e` kills us right
# here with curl's own error — that's fine, it's loud. But the *parsing*
# pipeline below must NOT be allowed to kill the script via set -e/pipefail
# when grep simply finds no match (e.g. a release with no .dmg asset) — that
# is exactly the silent-death bug this script used to have. So the parse is
# suffixed with `|| true` and its result is checked with an explicit guard.
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
DMG_URL="$(printf '%s' "${RELEASE_JSON}" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 \
  | sed -E 's/.*"(https[^"]+)"/\1/' || true)"
if [ -z "${DMG_URL}" ]; then
  echo "error: no .dmg asset found on the latest release of ${REPO}" >&2
  exit 1
fi

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  if [ -n "${MNT}" ]; then
    hdiutil detach "${MNT}" -quiet 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

echo "==> Downloading ${DMG_URL##*/} (via curl — no quarantine flag)…"
curl -fL "${DMG_URL}" -o "${TMP}/Clipnest.dmg"

echo "==> Mounting…"
# NOTE: `-quiet` here was the root cause of a silent-exit bug — it suppresses
# ALL of hdiutil's stdout (the mount table), so the grep below always came up
# empty, grep exited 1, and under `set -euo pipefail` that killed the script
# at this assignment line — BEFORE the `[ -z "${MNT}" ]` guard below ever ran.
# Fix: capture the (now non-empty) attach output first, parse it second, and
# never let the parse pipeline itself trigger set -e (see `|| true` above).
ATTACH_OUT="$(hdiutil attach "${TMP}/Clipnest.dmg" -nobrowse -noverify -noautoopen)"
MNT="$(printf '%s' "${ATTACH_OUT}" | grep -oE '/Volumes/.+$' | tail -1 || true)"
if [ -z "${MNT}" ] || [ ! -d "${MNT}/${APP}" ]; then
  echo "error: mounted the DMG but couldn't find ${APP} inside it" >&2
  echo "--- hdiutil attach output ---" >&2
  echo "${ATTACH_OUT}" >&2
  exit 1
fi

echo "==> Installing to ${DEST}…"
rm -rf "${DEST:?}/${APP}"
cp -R "${MNT}/${APP}" "${DEST}/"
# Belt-and-suspenders: strip quarantine in case a previous browser download set it.
xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true

if [ ! -d "${DEST}/${APP}" ]; then
  echo "error: install failed — ${DEST}/${APP} does not exist after copy" >&2
  exit 1
fi
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${DEST}/${APP}/Contents/Info.plist" 2>/dev/null || echo 'unknown')"

echo "==> Launching Clipnest…"
open "${DEST}/${APP}"

echo "Done. Clipnest ${INSTALLED_VERSION} is in ${DEST} and running in your menu bar (⌥⌘V to open the picker)."
