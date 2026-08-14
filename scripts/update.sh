#!/usr/bin/env bash
#
# Clipnest updater — curl-based, no Homebrew, no Apple Developer ID required.
#
# Same reasoning as scripts/install.sh: `curl` does not set the macOS
# `com.apple.quarantine` flag, so the updated app launches without the "Apple
# could not verify … is free of malware" Gatekeeper dialog. Only updates if the
# latest release is newer than the installed copy.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash

set -euo pipefail

REPO="AayushGour/clipnest"
APP="Clipnest.app"
DEST="/Applications"
APP_PATH="${DEST}/${APP}"

if [ ! -d "${APP_PATH}" ]; then
  echo "Clipnest isn't installed in ${DEST}. Install it first:"
  echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash"
  exit 1
fi

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo 'unknown')"

echo "==> Checking latest release…"
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
# Parse pipelines that end in `grep -o` must never be allowed to kill the
# script via set -e/pipefail on a simple "no match" — grep exiting 1 there is
# an expected, recoverable outcome (e.g. a malformed release), not a fatal
# error, and it must reach the explicit guard below instead of dying silently
# mid-assignment (this was the exact shape of the mount-parsing bug).
LATEST="$(printf '%s' "${RELEASE_JSON}" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)"
LATEST="${LATEST#v}"
if [ -z "${LATEST}" ]; then
  echo "error: could not determine the latest release version" >&2
  exit 1
fi

echo "    installed: ${INSTALLED}    latest: ${LATEST}"
if [ "${INSTALLED}" = "${LATEST}" ]; then
  echo "Already up to date."
  exit 0
fi

DMG_URL="$(printf '%s' "${RELEASE_JSON}" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/' || true)"
if [ -z "${DMG_URL}" ]; then
  echo "error: no .dmg asset found on the latest release" >&2
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

echo "==> Quitting the running Clipnest…"
osascript -e 'quit app "Clipnest"' 2>/dev/null || pkill -x Clipnest 2>/dev/null || true
sleep 1

echo "==> Installing ${LATEST} to ${DEST}…"
rm -rf "${APP_PATH}"
cp -R "${MNT}/${APP}" "${DEST}/"
xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true

if [ ! -d "${APP_PATH}" ]; then
  echo "error: update failed — ${APP_PATH} does not exist after copy" >&2
  exit 1
fi
NEW_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo 'unknown')"
if [ "${NEW_VERSION}" != "${LATEST}" ]; then
  echo "error: post-update version (${NEW_VERSION}) does not match expected latest (${LATEST})" >&2
  exit 1
fi

echo "==> Relaunching Clipnest…"
open "${APP_PATH}"
echo "Updated to ${NEW_VERSION}."
