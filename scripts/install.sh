#!/usr/bin/env bash
#
# Clipnest installer — one command for macOS and Linux (Ubuntu).
#
# It detects the OS (uname -s), finds the latest GitHub release, verifies the
# download and installs it. macOS: .dmg -> /Applications. Linux: the per-arch
# tarball, then its bundled install.sh (apt). No Homebrew, no Apple Developer ID.
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
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
#
# Or download it and run `bash install.sh`.
#
# Optional environment variables:
#   GITHUB_TOKEN      A GitHub personal access token (no scopes needed for a
#                      public repo). Only used to raise the GitHub API rate
#                      limit from 60/hr to 5000/hr per IP; never required,
#                      never printed, never written to disk.
#   REQUIRE_CHECKSUM   macOS only. See the block below — controls fail-closed
#                      behavior when a release has no published checksum.
#   CLIPNEST_DRY_RUN=1 Detect, fetch and verify, but skip the actual install.
#   CLIPNEST_FORCE=1   Linux only: continue on a system that is not Ubuntu
#                      22.04/24.04 with GNOME (unsupported; may not work).
#
# Linux verification: release tarballs have no .sha256 sibling, so the tarball
# is checked against the SHA-256 "digest" GitHub's API reports for the asset,
# then the files inside against the tarball's own SHA256SUMS. Missing or
# mismatched digest aborts (fail closed).


set -euo pipefail

REPO="AayushGour/clipnest"
APP="Clipnest.app"
DEST="/Applications"
SUPPORTED_UBUNTU_VERSIONS="22.04 24.04"
SUPPORTED_UBUNTU_TEXT="22.04 or 24.04"
CLIPNEST_DRY_RUN="${CLIPNEST_DRY_RUN:-0}"
CLIPNEST_FORCE="${CLIPNEST_FORCE:-0}"

# Every curl: HTTPS only (including redirects), TLS 1.2+.
CURL_SEC=(--proto '=https' --proto-redir '=https' --tlsv1.2)

# --- Fail-closed checksum policy (macOS) ------------------------------------
# When "true" (the default), the macOS path ABORTS rather than installing if the
# GitHub release has no published `*.dmg.sha256` checksum asset — an
# unverifiable download is treated as untrusted, not "probably fine". Flip to
# "false" only if you deliberately want to allow installing an unverified
# .dmg from a release that predates checksum publishing. A checksum MISMATCH
# always aborts, regardless of this setting.
REQUIRE_CHECKSUM="${REQUIRE_CHECKSUM:-true}"

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

TMP=""
MNT=""
cleanup() {
  swap_cleanup
  if [ -n "${MNT}" ]; then
    hdiutil detach "${MNT}" -quiet 2>/dev/null || true
  fi
  if [ -n "${TMP}" ]; then
    rm -rf "${TMP}"
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Fetches the latest release JSON into RELEASE_JSON (shared by both OS paths).
fetch_release() {
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
      echo "         curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash" >&2
    else
      echo "GitHub's response body:" >&2
      cat "${API_BODY_FILE}" >&2 2>/dev/null || true
    fi
    exit 1
  fi
  RELEASE_JSON="$(cat "${API_BODY_FILE}")"
}

# Prints the first 64-hex SHA-256 from stdin, lowercased (empty if none).
extract_sha256() {
  grep -oE '[0-9a-fA-F]{64}' | head -1 | tr '[:upper:]' '[:lower:]' || true
}

# sha256_of FILE -> hex digest, using whichever tool the OS has.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi | tr '[:upper:]' '[:lower:]'
}

# asset_digest NAME: the sha256 GitHub's API reports for the release asset NAME,
# read from RELEASE_JSON. Pairs each asset's own "name" with its own "digest"
# (the digest follows the name inside the same asset object; a new "name"
# resets the pairing, so an asset with a null/missing digest yields nothing).
asset_digest() {
  printf '%s\n' "${RELEASE_JSON}" | awk -v want="$1" '
    /"name":/ {
      cur = $0
      sub(/^[^:]*:[[:space:]]*"/, "", cur); sub(/".*$/, "", cur)
      next
    }
    /"digest":[[:space:]]*"sha256:/ && cur == want {
      d = $0
      sub(/^.*"sha256:/, "", d); sub(/".*$/, "", d)
      print tolower(d); exit
    }'
}

# asset_url NAME: browser_download_url of the release asset NAME.
asset_url() {
  printf '%s\n' "${RELEASE_JSON}" \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | sed -E 's/.*"(https[^"]+)"/\1/' \
    | grep -F "/$1" | grep -E "/$1\$" | head -1 || true
}

# verify_sha256 FILE EXPECTED LABEL: aborts on empty/mismatched digest.
verify_sha256() {
  local file="$1" expected="$2" label="$3" actual
  if [ -z "${expected}" ]; then
    die "no SHA-256 digest available for ${label}; refusing to install an unverifiable download."
  fi
  actual="$(sha256_of "${file}")"
  if [ "${expected}" != "${actual}" ]; then
    {
      echo ""
      echo "############################################################"
      echo "# SECURITY: CHECKSUM MISMATCH — REFUSING TO INSTALL         #"
      echo "############################################################"
      echo "${label} does NOT match its published SHA-256. It was corrupted in"
      echo "transit or tampered with, and will NOT be installed."
      echo "  expected: ${expected}"
      echo "  actual:   ${actual}"
      echo "Confirm you're downloading from https://github.com/${REPO}/releases"
      echo "and report this if it persists."
    } >&2
    exit 1
  fi
  echo "==> Checksum verified OK (sha256 ${actual})"
}

install_macos() {
  echo "==> macOS detected."
  fetch_release


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

  if [ "${CLIPNEST_DRY_RUN}" = "1" ]; then
    echo "==> Dry run: ${DMG_URL##*/} downloaded and verified. Would mount it and install ${APP} to ${DEST}; skipping."
    return 0
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

  # Stage-then-swap (see the swap block near the top): the new app is verified
  # (version, code signature, same signer as any existing install) BEFORE an
  # existing copy is touched, and the old copy is restored if the swap fails.
  EXPECTED_VERSION="$(printf '%s' "${RELEASE_JSON}" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)"
  EXPECTED_VERSION="${EXPECTED_VERSION#v}"
  [ -n "${EXPECTED_VERSION}" ] || die "could not determine the release version"
  echo "==> Installing to ${DEST}…"
  stage_app "${MNT}/${APP}" "${DEST}/${APP}" "${EXPECTED_VERSION}" \
    || die "install aborted; any existing ${DEST}/${APP} was NOT modified."
  commit_swap || die "install failed; any previous ${DEST}/${APP} was restored."
  INSTALLED_VERSION="$(app_plist_version "${DEST}/${APP}")"

  echo "==> Launching Clipnest…"
  open "${DEST}/${APP}"

  echo "Done. Clipnest ${INSTALLED_VERSION} is in ${DEST} and running in your menu bar (⌥⌘V to open the picker)."
}

os_release_value() {
  # Reads KEY from /etc/os-release without sourcing it.
  sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -1 | tr -d '"'
}

install_linux() {
  if [ "$(id -u)" -eq 0 ]; then
    die "run this as your normal user, not root — the installer uses sudo only where needed."
  fi

  local os_id os_ver desktop supported=0 v
  os_id="$(os_release_value ID)"
  os_ver="$(os_release_value VERSION_ID)"
  desktop="${XDG_CURRENT_DESKTOP:-}"
  if [ "${os_id}" = "ubuntu" ]; then
    for v in ${SUPPORTED_UBUNTU_VERSIONS}; do
      [ "${os_ver}" = "${v}" ] && supported=1
    done
  fi
  case "${desktop}" in *GNOME*) ;; *) supported=0 ;; esac
  if [ "${supported}" != "1" ]; then
    echo "Detected: ${os_id:-unknown} ${os_ver:-?}, desktop '${desktop:-none}'." >&2
    echo "Clipnest supports Ubuntu ${SUPPORTED_UBUNTU_TEXT} with GNOME (X11 or Wayland)." >&2
    if [ "${CLIPNEST_FORCE}" != "1" ]; then
      echo "Stopping. To try anyway (unsupported), re-run with CLIPNEST_FORCE=1." >&2
      exit 1
    fi
    echo "WARNING: CLIPNEST_FORCE=1 set — continuing on an unsupported system." >&2
  fi

  local arch
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported CPU architecture '$(uname -m)' (need x86_64 or aarch64)." ;;
  esac

  local tool
  for tool in curl tar awk; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool '${tool}' not found."
  done
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "required tool 'sha256sum' not found."
  if [ "${CLIPNEST_DRY_RUN}" != "1" ]; then
    for tool in sudo apt-get; do
      command -v "${tool}" >/dev/null 2>&1 || die "required tool '${tool}' not found."
    done
  fi
  echo "==> Linux (${os_id:-?} ${os_ver:-?}, ${arch}) detected."

  fetch_release
  local tag asset url expected
  tag="$(printf '%s' "${RELEASE_JSON}" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  asset="$(printf '%s\n' "${RELEASE_JSON}" | grep -o "\"name\": *\"clipnest-[^\"]*-linux-${arch}\.tar\.gz\"" | head -1 | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  [ -n "${asset}" ] || die "no linux-${arch} tarball found on the latest release of ${REPO}."
  url="$(asset_url "${asset}")"
  [ -n "${url}" ] || die "couldn't find the download URL for ${asset}."
  expected="$(asset_digest "${asset}")"
  [ -n "${expected}" ] || die "the release publishes no SHA-256 digest for ${asset}; refusing to install an unverifiable download."

  echo "==> Downloading ${asset} (${tag:-latest})…"
  curl "${CURL_SEC[@]}" -fSL --progress-bar "${url}" -o "${TMP}/${asset}"
  echo "==> Verifying integrity (SHA-256) before extracting…"
  verify_sha256 "${TMP}/${asset}" "${expected}" "${asset}"

  tar -xzf "${TMP}/${asset}" -C "${TMP}"
  local dir="${TMP}/${asset%.tar.gz}"
  [ -f "${dir}/install.sh" ] || die "${asset} has no install.sh inside."
  echo "==> Verifying package files against the bundled SHA256SUMS…"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${dir}" && sha256sum -c SHA256SUMS) || die "bundled SHA256SUMS check failed."
  else
    (cd "${dir}" && shasum -a 256 -c SHA256SUMS) || die "bundled SHA256SUMS check failed."
  fi

  if [ "${CLIPNEST_DRY_RUN}" = "1" ]; then
    echo "==> Dry run: would run ${asset%.tar.gz}/install.sh (sudo apt-get install of clipnest, clipnest-ocr, clipnest-ocr-data); skipping."
    return 0
  fi

  echo "==> Installing (sudo will ask for your password)…"
  (cd "${dir}" && bash ./install.sh)

  cat <<'HINTS'

Next steps:
  - Open the picker with Alt+Super+V (or run: clipnest-ctl toggle-picker).
  - Auto-paste needs one permission: Settings -> Permissions. Log out and back
    in afterwards for it to take effect. Without it, Clipnest still copies to
    your clipboard and you paste manually.
HINTS
}

main() {
  TMP="$(mktemp -d)"
  trap cleanup EXIT
  case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux) install_linux ;;
    *) die "unsupported OS '$(uname -s)'. Clipnest supports macOS and Linux (Ubuntu)." ;;
  esac
}

# CLIPNEST_SOURCE_ONLY=1 lets tests source the functions without running them.
# Everything above is function definitions, so a truncated `curl | bash`
# download can never execute a partial install: main only runs once this last
# line has arrived.
if [ "${CLIPNEST_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
