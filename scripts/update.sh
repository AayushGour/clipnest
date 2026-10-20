#!/usr/bin/env bash
#
# Clipnest updater — curl-based, no Homebrew, no Apple Developer ID required.
#
# Same reasoning as scripts/install.sh: `curl` does not set the macOS
# `com.apple.quarantine` flag, so the updated app launches without the "Apple
# could not verify … is free of malware" Gatekeeper dialog. Only updates if the
# latest release is newer than the installed copy. Also same as install.sh:
# because Gatekeeper's own signature check is bypassed, this script verifies
# the downloaded .dmg against a published SHA-256 checksum BEFORE mounting it
# (see REQUIRE_CHECKSUM below).
#
# Usage:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
#
# The in-app updater does NOT run the `main` copy: it fetches this script from
# the release TAG being installed and pins the version (see CLIPNEST_VERSION).
#
# Safety properties (T-AUD-UPDPIN): HTTPS-only curl; DMG SHA-256 verified
# before mounting; `hdiutil attach` verifies the image too; the new app is
# staged next to the old one, its version + code signature verified (and
# required to match the installed app's signer) BEFORE anything is replaced,
# and the old app is restored if the swap fails. See "Stage-then-swap" below.
#
# Optional environment variables:
#   CLIPNEST_VERSION   Pin the release to install, as a tag like `v1.4.1`
#                      (strictly ^v[0-9]+\.[0-9]+\.[0-9]+$, anything else is
#                      rejected). Unset = install the latest release.
#   CLIPNEST_RELEASE_IDENTITY  Expected signing-identity name when the
#                      installed app has no comparable signature (default
#                      "Clipnest Release").
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
APP_PATH="${DEST}/${APP}"

# Every curl: HTTPS only (including redirects), TLS 1.2+.
CURL_SEC=(--proto '=https' --proto-redir '=https' --tlsv1.2)

# Optional version pin. Validated BEFORE it is used in any URL or message so a
# hostile value can't inject anything. `[[ =~ ]]` with the pattern in a
# variable works on bash 3.2; `$` anchors at end-of-string (no trailing
# newline slips through).
PINNED_TAG="${CLIPNEST_VERSION:-}"
TAG_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+$'
if [ -n "${PINNED_TAG}" ] && ! [[ "${PINNED_TAG}" =~ ${TAG_REGEX} ]]; then
  echo "error: CLIPNEST_VERSION must look like v1.2.3 (got an invalid value); refusing to continue." >&2
  exit 1
fi

# --- Fail-closed checksum policy --------------------------------------------
# When "true" (the default), this script ABORTS rather than updating if the
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

if [ ! -d "${APP_PATH}" ]; then
  echo "Clipnest isn't installed in ${DEST}. Install it first:"
  echo "  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash"
  exit 1
fi

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo 'unknown')"

# --- Stage-then-swap + signature continuity ---------------------------------
# BEGIN swap block (keep byte-identical with the same block in scripts/install.sh;
# scripts/update.sh and install.sh are each run standalone via `curl | bash`, so
# they cannot share a sourced file. The fixture test diffs the two blocks.)
#
# Why: the old flow was `rm -rf /Applications/Clipnest.app && cp -R new …`; a
# failed copy (full disk, permissions, kill) left NO app and no way back. Now
# the new app is copied NEXT TO the old one (same volume, hidden temp name),
# fully verified, and only then swapped with two renames; any failure puts the
# old app back. Nothing destructive happens before verification passes.
#
# Signature continuity (SECURITY): the SHA-256 check only proves the .dmg is
# the one the release published; it does not prove the app inside is signed
# by the same party as the app already installed. Before swapping we require:
#   1. the staged app's version == the expected release version,
#   2. `codesign --verify --deep --strict` passes on the staged app,
#   3. identity continuity:
#        - if the installed app is validly signed with a certificate-based
#          designated requirement (DR), the staged app MUST satisfy that exact
#          DR (same release certificate — also what keeps users' Accessibility
#          grant alive across updates);
#        - otherwise (nothing installed, unsigned, or ad-hoc/cdhash-only DR,
#          which cannot be compared across builds) the staged app's leaf
#          signing authority MUST equal the release identity name below
#          ("Clipnest Release", the CN created by scripts/release-cert.sh).
#          NOTE: that release cert is self-signed, so this fallback proves
#          "signed by a cert with the expected name", not a trusted CA chain —
#          it is defence in depth on top of the checksum, not a replacement.
# A mismatch aborts with a loud SECURITY message and the old app is untouched.
RELEASE_IDENTITY="${CLIPNEST_RELEASE_IDENTITY:-Clipnest Release}"
SWAP_STAGED=""
SWAP_BACKUP=""
SWAP_DEST=""

app_plist_version() {
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo 'unknown'
}

# Put the old app back if we died between the two renames, and drop the
# staging dir. Safe to call repeatedly / when nothing is in flight.
swap_cleanup() {
  if [ -n "${SWAP_BACKUP}" ] && [ -e "${SWAP_BACKUP}" ] && [ ! -e "${SWAP_DEST}" ]; then
    mv "${SWAP_BACKUP}" "${SWAP_DEST}" 2>/dev/null || true
  fi
  if [ -n "${SWAP_STAGED}" ]; then rm -rf "${SWAP_STAGED}"; fi
  SWAP_STAGED=""
  SWAP_BACKUP=""
}

# verify_signature_continuity <new.app> <installed.app>; 0 = same signer.
verify_signature_continuity() {
  local new="$1" old="$2" dr="" authority=""
  if [ -d "${old}" ] && codesign --verify --deep --strict "${old}" >/dev/null 2>&1; then
    dr="$(codesign -d -r- "${old}" 2>&1 | sed -n 's/^designated => //p' | head -1 || true)"
  fi
  case "${dr}" in *cdhash*) dr="" ;; esac
  if [ -n "${dr}" ]; then
    if codesign --verify --deep --strict -R="${dr}" "${new}" >/dev/null 2>&1; then
      echo "    signature OK: new app satisfies the installed app's designated requirement"
      return 0
    fi
    echo "" >&2
    echo "############################################################" >&2
    echo "# SECURITY: SIGNATURE MISMATCH — REFUSING TO UPDATE         #" >&2
    echo "############################################################" >&2
    echo "The new app is NOT signed by the same identity as the installed" >&2
    echo "Clipnest. It will NOT be installed; your existing app is untouched." >&2
    echo "  installed requirement: ${dr}" >&2
    echo "Report this at https://github.com/${REPO}/issues if it persists." >&2
    return 1
  fi
  authority="$(codesign -dvv "${new}" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
  if [ "${authority}" = "${RELEASE_IDENTITY}" ]; then
    echo "    signature OK: new app is signed by '${authority}'"
    return 0
  fi
  echo "" >&2
  echo "############################################################" >&2
  echo "# SECURITY: UNEXPECTED SIGNER — REFUSING TO INSTALL         #" >&2
  echo "############################################################" >&2
  echo "No comparable signature on the installed app, and the new app's" >&2
  echo "signing authority is not the Clipnest release identity." >&2
  echo "  expected: ${RELEASE_IDENTITY}" >&2
  echo "  actual:   ${authority:-<none / unsigned>}" >&2
  echo "Nothing was installed; any existing app is untouched." >&2
  return 1
}

# stage_app <src.app> <dest.app> <expected_version>: copy next to dest, verify.
# On success SWAP_STAGED is set and nothing at dest has been touched.
stage_app() {
  local src="$1" dest="$2" expected="$3" dir base staged actual
  dir="$(dirname "${dest}")"
  base="$(basename "${dest}")"
  staged="${dir}/.${base}.new-$$"
  SWAP_DEST="${dest}"
  SWAP_STAGED="${staged}"
  SWAP_BACKUP=""
  rm -rf "${staged:?}"
  if ! cp -R "${src}" "${staged}"; then
    echo "error: could not copy the new app to ${dir} (disk full / not writable?). Existing app untouched." >&2
    swap_cleanup
    return 1
  fi
  actual="$(app_plist_version "${staged}")"
  if [ "${actual}" != "${expected}" ]; then
    echo "error: new app version (${actual}) does not match expected (${expected}). Existing app untouched." >&2
    swap_cleanup
    return 1
  fi
  if ! codesign --verify --deep --strict "${staged}" >/dev/null 2>&1; then
    echo "error: SECURITY — the new app's code signature is missing or invalid. Existing app untouched." >&2
    swap_cleanup
    return 1
  fi
  if ! verify_signature_continuity "${staged}" "${dest}"; then
    swap_cleanup
    return 1
  fi
  /usr/bin/xattr -dr com.apple.quarantine "${staged}" 2>/dev/null || true
  return 0
}

# commit_swap: rename old -> .old-$$, staged -> dest, then drop old. Rolls back on failure.
commit_swap() {
  local dest="${SWAP_DEST}" staged="${SWAP_STAGED}" dir base backup
  dir="$(dirname "${dest}")"
  base="$(basename "${dest}")"
  backup="${dir}/.${base}.old-$$"
  if [ -e "${dest}" ]; then
    rm -rf "${backup:?}"
    if ! mv "${dest}" "${backup}"; then
      echo "error: could not move the old app aside. Existing app untouched." >&2
      swap_cleanup
      return 1
    fi
    SWAP_BACKUP="${backup}"
  fi
  if ! mv "${staged}" "${dest}"; then
    echo "error: could not move the new app into place — restoring the previous version." >&2
    swap_cleanup
    return 1
  fi
  SWAP_STAGED=""
  rm -rf "${backup:?}"
  SWAP_BACKUP=""
  return 0
}
# END swap block

TMP="$(mktemp -d)"
MNT=""
cleanup() {
  swap_cleanup
  if [ -n "${MNT}" ]; then
    hdiutil detach "${MNT}" -quiet 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

echo "==> Checking latest release…"
# GitHub's unauthenticated REST API is rate-limited to 60 requests/hour per
# IP; once exhausted, every call 403s. We deliberately do NOT use curl's `-f`
# here (it suppresses the response body on a non-2xx, and `-s` hides
# everything else) — that combination is exactly what used to make a rate
# limit look like an opaque, unexplained failure. Instead we capture the
# HTTP status and body ourselves so we can print GitHub's actual reason.
# GITHUB_TOKEN, if set in the environment, is sent as a bearer token to raise
# the limit to 5000/hr — it is optional, never required, never echoed, and
# never written anywhere but curl's own request header.
if [ -n "${PINNED_TAG}" ]; then
  API_URL="https://api.github.com/repos/${REPO}/releases/tags/${PINNED_TAG}"
else
  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
fi
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
API_STATUS="$(curl "${CURL_SEC[@]}" -sS ${CURL_AUTH_ARGS[@]+"${CURL_AUTH_ARGS[@]}"} \
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
    echo "         curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/update.sh | bash" >&2
  else
    echo "GitHub's response body:" >&2
    cat "${API_BODY_FILE}" >&2 2>/dev/null || true
  fi
  exit 1
fi
RELEASE_JSON="$(cat "${API_BODY_FILE}")"

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
# Validate before LATEST is echoed or used in a path: release metadata is
# remote input.
if ! [[ "${LATEST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: release metadata has an unexpected version format" >&2
  exit 1
fi

if [ -n "${PINNED_TAG}" ] && [ "${LATEST}" != "${PINNED_TAG#v}" ]; then
  echo "error: release metadata (${LATEST}) does not match the pinned version (${PINNED_TAG})" >&2
  exit 1
fi

echo "    installed: ${INSTALLED}    latest: ${LATEST}"

# Mirrors UpdateChecker.isUpdateAvailable (the in-app check): update only
# when LATEST is strictly NEWER, compared numerically per dot-separated
# component. Plain inequality used to "update" a build that was ahead of
# the latest release DOWN to it. A non-numeric version on either side is
# never treated as an update; "unknown" (nothing installed yet) still
# installs.
is_newer() {
  local installed="$1" latest="$2" i a b
  case "${installed}.${latest}" in *[!0-9.]*) return 1 ;; esac
  IFS=. read -r -a a <<<"${installed}"
  IFS=. read -r -a b <<<"${latest}"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    if ((10#${b[i]:-0} > 10#${a[i]:-0})); then return 0; fi
    if ((10#${b[i]:-0} < 10#${a[i]:-0})); then return 1; fi
  done
  return 1
}

if [ "${INSTALLED}" != "unknown" ] && ! is_newer "${INSTALLED}" "${LATEST}"; then
  echo "Already up to date."
  exit 0
fi

DMG_URL="$(printf '%s' "${RELEASE_JSON}" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/' || true)"
if [ -z "${DMG_URL}" ]; then
  echo "error: no .dmg asset found on the latest release" >&2
  exit 1
fi

# Same safe-parse idiom as DMG_URL above: a release with no checksum asset is
# a legitimate ("just not published yet") outcome, not a script bug, so this
# must reach the REQUIRE_CHECKSUM guard below rather than dying here.
CHECKSUM_URL="$(printf '%s' "${RELEASE_JSON}" | grep -o '"browser_download_url": *"[^"]*\.dmg\.sha256"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/' || true)"

echo "==> Downloading ${DMG_URL##*/} (via curl — no quarantine flag)…"
curl "${CURL_SEC[@]}" -fL "${DMG_URL}" -o "${TMP}/Clipnest.dmg"

echo "==> Verifying integrity (SHA-256) before mounting…"
if [ -n "${CHECKSUM_URL}" ]; then
  CHECKSUM_RAW="$(curl "${CURL_SEC[@]}" -fsSL "${CHECKSUM_URL}")"
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
    echo "# SECURITY: CHECKSUM MISMATCH — REFUSING TO UPDATE          #" >&2
    echo "############################################################" >&2
    echo "The downloaded ${DMG_URL##*/} does NOT match the SHA-256 checksum" >&2
    echo "published on the release. This means the file was corrupted in" >&2
    echo "transit or tampered with. It will NOT be mounted or installed." >&2
    echo "Your existing installation at ${APP_PATH} has NOT been touched." >&2
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
    echo "Your existing installation at ${APP_PATH} has NOT been touched." >&2
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
# `-noverify` was removed: the SHA-256 above authenticates the file, and now
# hdiutil also verifies the image's own UDIF checksum while attaching.
# NOTE: `-quiet` here was the root cause of a silent-exit bug — it suppresses
# ALL of hdiutil's stdout (the mount table), so the grep below always came up
# empty, grep exited 1, and under `set -euo pipefail` that killed the script
# at this assignment line — BEFORE the `[ -z "${MNT}" ]` guard below ever ran.
# Fix: capture the (now non-empty) attach output first, parse it second, and
# never let the parse pipeline itself trigger set -e (see `|| true` above).
ATTACH_OUT="$(hdiutil attach "${TMP}/Clipnest.dmg" -nobrowse -noautoopen)"
MNT="$(printf '%s' "${ATTACH_OUT}" | grep -oE '/Volumes/.+$' | tail -1 || true)"
if [ -z "${MNT}" ] || [ ! -d "${MNT}/${APP}" ]; then
  echo "error: mounted the DMG but couldn't find ${APP} inside it" >&2
  echo "--- hdiutil attach output ---" >&2
  echo "${ATTACH_OUT}" >&2
  exit 1
fi

echo "==> Staging + verifying ${LATEST} (version, code signature, signer)…"
if ! stage_app "${MNT}/${APP}" "${APP_PATH}" "${LATEST}"; then
  echo "error: update aborted; ${APP_PATH} was NOT modified." >&2
  exit 1
fi

echo "==> Quitting the running Clipnest…"
osascript -e 'quit app "Clipnest"' 2>/dev/null || pkill -x Clipnest 2>/dev/null || true
sleep 1

echo "==> Installing ${LATEST} to ${DEST}…"
if ! commit_swap; then
  echo "error: update failed; the previous version was restored at ${APP_PATH}." >&2
  open "${APP_PATH}" 2>/dev/null || true
  exit 1
fi

NEW_VERSION="$(app_plist_version "${APP_PATH}")"

echo "==> Relaunching Clipnest…"
open "${APP_PATH}"
echo "Updated to ${NEW_VERSION}."
