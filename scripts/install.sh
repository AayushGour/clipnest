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
DMG_URL="$(
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
    | head -1 \
    | sed -E 's/.*"(https[^"]+)"/\1/'
)"
if [ -z "${DMG_URL}" ]; then
  echo "error: no .dmg asset found on the latest release of ${REPO}" >&2
  exit 1
fi

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  [ -n "${MNT}" ] && hdiutil detach "${MNT}" -quiet 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

echo "==> Downloading ${DMG_URL##*/} (via curl — no quarantine flag)…"
curl -fL "${DMG_URL}" -o "${TMP}/Clipnest.dmg"

echo "==> Mounting…"
MNT="$(hdiutil attach "${TMP}/Clipnest.dmg" -nobrowse -quiet | grep -o '/Volumes/[^[:cntrl:]]*' | tail -1)"
if [ -z "${MNT}" ] || [ ! -d "${MNT}/${APP}" ]; then
  echo "error: could not mount the DMG or find ${APP} inside it" >&2
  exit 1
fi

echo "==> Installing to ${DEST}…"
rm -rf "${DEST:?}/${APP}"
cp -R "${MNT}/${APP}" "${DEST}/"
# Belt-and-suspenders: strip quarantine in case a previous browser download set it.
xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true

echo "==> Launching Clipnest…"
open "${DEST}/${APP}"

echo "Done. Clipnest is in ${DEST} and running in your menu bar (⌥⌘V to open the picker)."
