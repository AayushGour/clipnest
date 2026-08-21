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
# Because that quarantine bit is what would normally trigger Gatekeeper's own
# signature check, this script does its OWN integrity check instead: it
# verifies the downloaded .dmg against a SHA-256 checksum published as a
# release asset (see REQUIRE_CHECKSUM below) BEFORE the .dmg is ever mounted.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
#
# Or download it and run `bash install.sh`.
#
# Optional environment variables:
#   GITHUB_TOKEN      A GitHub personal access token (no scopes needed for a
#                      public repo). Only used to raise the GitHub API rate
#                      limit from 60/hr to 5000/hr per IP; never required,
#                      never printed, never written to disk.
#   REQUIRE_CHECKSUM   See the block below — controls fail-closed behavior
#                      when a release has no published checksum.

set -euo pipefail

REPO="AayushGour/clipnest"
APP="Clipnest.app"
DEST="/Applications"

# --- Fail-closed checksum policy --------------------------------------------
# When "true" (the default), this script ABORTS rather than installing if the
# GitHub release has no published `*.dmg.sha256` checksum asset — an
# unverifiable download is treated as untrusted, not "probably fine". This is
# the ONLY switch in this script that controls that behavior; flip it to
# "false" only if you deliberately want to allow installing an unverified
# .dmg from a release that predates checksum publishing, and you understand
# the download is then unauthenticated (equivalent to the pre-fix behavior).
# A checksum MISMATCH (as opposed to a missing checksum) always aborts,
# regardless of this setting — that case means the file is provably wrong,
# not merely unverifiable.
REQUIRE_CHECKSUM="${REQUIRE_CHECKSUM:-true}"

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  if [ -n "${MNT}" ]; then
    hdiutil detach "${MNT}" -quiet 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

echo "==> Finding the latest Clipnest release…"
# GitHub's unauthenticated REST API is rate-limited to 60 requests/hour per
# IP; once exhausted, every call 403s. We deliberately do NOT use curl's `-f`
# here (it suppresses the response body on a non-2xx, and `-s` hides
# everything else) — that combination is exactly what used to make a rate
# limit look like an opaque, unexplained failure. Instead we capture the
# HTTP status and body ourselves so we can print GitHub's actual reason.
# GITHUB_TOKEN, if set in the environment, is sent as a bearer token to raise
# the limit to 5000/hr — it is optional, never required, never echoed, and
# never written anywhere but curl's own request header.
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
CURL_AUTH_ARGS=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURL_AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi
API_BODY_FILE="${TMP}/release.json"
API_HEADERS_FILE="${TMP}/release.headers"
# The `${CURL_AUTH_ARGS[@]+"${CURL_AUTH_ARGS[@]}"}` shape (not the plain
# `"${CURL_AUTH_ARGS[@]}"` you'd write on a modern bash) is required because
# this runs on macOS's shipped /bin/bash 3.2, where `set -u` treats
# expanding a *zero-element* array as an unbound-variable error (fixed only
# in bash 4.4+) — the GITHUB_TOKEN-unset case, i.e. almost every run. The
# `+` form is the standard 3.2-safe idiom: expand-if-set instead of
# expand-and-fail-if-empty.
API_STATUS="$(curl -sS ${CURL_AUTH_ARGS[@]+"${CURL_AUTH_ARGS[@]}"} \
  -D "${API_HEADERS_FILE}" \
  -o "${API_BODY_FILE}" \
  -w '%{http_code}' \
  "${API_URL}")"

if [ "${API_STATUS}" != "200" ]; then
  echo "error: GitHub API request failed (HTTP ${API_STATUS}) for ${API_URL}" >&2
  if [ "${API_STATUS}" = "403" ] && grep -qi 'rate limit' "${API_BODY_FILE}" 2>/dev/null; then
    RESET_EPOCH="$(grep -i '^x-ratelimit-reset:' "${API_HEADERS_FILE}" \
      | tail -1 | tr -d '\r' | sed -E 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset:[[:space:]]*//' || true)"
    echo "error: GitHub's unauthenticated API rate limit (60 requests/hour/IP) is exhausted." >&2
    if [ -n "${RESET_EPOCH}" ]; then
      RESET_HUMAN="$(date -r "${RESET_EPOCH}" 2>/dev/null || echo "unknown")"
      echo "       It resets at: ${RESET_HUMAN} (unix time ${RESET_EPOCH})." >&2
    fi
    echo "       Fix: wait for the reset, or set GITHUB_TOKEN to a GitHub personal" >&2
    echo "       access token (no scopes needed for a public repo) to raise the" >&2
    echo "       limit to 5000/hour, e.g.:" >&2
    echo "         export GITHUB_TOKEN=ghp_xxx" >&2
    echo "         curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash" >&2
  else
    echo "GitHub's response body:" >&2
    cat "${API_BODY_FILE}" >&2 2>/dev/null || true
  fi
  exit 1
fi
RELEASE_JSON="$(cat "${API_BODY_FILE}")"

# Fetch first, parse second: if `curl` itself fails, `set -e` kills us right
# here with curl's own error — that's fine, it's loud. But the *parsing*
# pipeline below must NOT be allowed to kill the script via set -e/pipefail
# when grep simply finds no match (e.g. a release with no .dmg asset) — that
# is exactly the silent-death bug this script used to have. So the parse is
# suffixed with `|| true` and its result is checked with an explicit guard.
DMG_URL="$(printf '%s' "${RELEASE_JSON}" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 \
  | sed -E 's/.*"(https[^"]+)"/\1/' || true)"
if [ -z "${DMG_URL}" ]; then
  echo "error: no .dmg asset found on the latest release of ${REPO}" >&2
  exit 1
fi

# Same safe-parse idiom as DMG_URL above: a release with no checksum asset is
# a legitimate ("just not published yet") outcome, not a script bug, so this
# must reach the REQUIRE_CHECKSUM guard below rather than dying here.
CHECKSUM_URL="$(printf '%s' "${RELEASE_JSON}" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg\.sha256"' \
  | head -1 \
  | sed -E 's/.*"(https[^"]+)"/\1/' || true)"

echo "==> Downloading ${DMG_URL##*/} (via curl — no quarantine flag)…"
curl -fL "${DMG_URL}" -o "${TMP}/Clipnest.dmg"

echo "==> Verifying integrity (SHA-256) before mounting…"
if [ -n "${CHECKSUM_URL}" ]; then
  CHECKSUM_RAW="$(curl -fsSL "${CHECKSUM_URL}")"
  EXPECTED_SHA="$(printf '%s' "${CHECKSUM_RAW}" \
    | grep -oE '[0-9a-fA-F]{64}' | head -1 | tr '[:upper:]' '[:lower:]' || true)"
  if [ -z "${EXPECTED_SHA}" ]; then
    echo "error: fetched a checksum asset (${CHECKSUM_URL##*/}) but couldn't parse a" >&2
    echo "       64-character SHA-256 hash out of it. Refusing to install an" >&2
    echo "       unverified download. Contents received:" >&2
    printf '%s\n' "${CHECKSUM_RAW}" >&2
    exit 1
  fi
  ACTUAL_SHA="$(shasum -a 256 "${TMP}/Clipnest.dmg" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
  if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
    echo "" >&2
    echo "############################################################" >&2
    echo "# SECURITY: CHECKSUM MISMATCH — REFUSING TO INSTALL         #" >&2
    echo "############################################################" >&2
    echo "The downloaded ${DMG_URL##*/} does NOT match the SHA-256 checksum" >&2
    echo "published on the release. This means the file was corrupted in" >&2
    echo "transit or tampered with. It will NOT be mounted or installed." >&2
    echo "  expected: ${EXPECTED_SHA}" >&2
    echo "  actual:   ${ACTUAL_SHA}" >&2
    echo "Do not retry blindly. Confirm you're downloading from" >&2
    echo "https://github.com/${REPO}/releases and report this if it persists." >&2
    exit 1
  fi
  echo "==> Checksum verified OK (sha256 ${ACTUAL_SHA})"
else
  if [ "${REQUIRE_CHECKSUM}" = "true" ]; then
    echo "" >&2
    echo "############################################################" >&2
    echo "# SECURITY: NO CHECKSUM PUBLISHED FOR THIS RELEASE          #" >&2
    echo "############################################################" >&2
    echo "This release has no *.dmg.sha256 checksum asset, so the downloaded" >&2
    echo ".dmg cannot be verified against what was actually published." >&2
    echo "Refusing to mount or install an unverifiable download." >&2
    echo "" >&2
    echo "What you can do:" >&2
    echo "  - Wait for a newer release (checksums are now published automatically" >&2
    echo "    by the release workflow going forward)." >&2
    echo "  - If you maintain this repo, publish a checksum on the existing" >&2
    echo "    release, e.g.:" >&2
    echo "      shasum -a 256 Clipnest-<version>.dmg > Clipnest-<version>.dmg.sha256" >&2
    echo "      gh release upload v<version> Clipnest-<version>.dmg.sha256" >&2
    echo "  - Only if you fully understand the risk, you can bypass this check" >&2
    echo "    by re-running with REQUIRE_CHECKSUM=false (NOT recommended)." >&2
    exit 1
  else
    echo "WARNING: no checksum asset published for this release — installing" >&2
    echo "         WITHOUT integrity verification (REQUIRE_CHECKSUM=false)." >&2
  fi
fi

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
