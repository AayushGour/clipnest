#!/usr/bin/env bash
#
# scripts/dev-install.sh — build the working tree, sign it with the local
# self-signed identity, and install it over /Applications/Clipnest.app.
#
# This is the LOCAL development install path. It is not the release path —
# that is build.sh -> sign.sh (Developer ID) -> notarize.sh -> package_dmg.sh.
#
# Signing with the stable identity from scripts/dev-cert.sh is the whole
# point: it is what stops macOS from silently dropping Clipnest's
# Accessibility grant on every rebuild. See that script's header for why.
#
# Usage:
#   scripts/dev-cert.sh      # once, ever
#   scripts/dev-install.sh   # every time you want the build on your Mac
#
# Env vars:
#   CLIPNEST_DEV_IDENTITY   Common Name of the signing identity.
#                           Must match scripts/dev-cert.sh. Default below.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${CLIPNEST_DEV_IDENTITY:-Clipnest Local Dev}"
BUILT_APP="$REPO_ROOT/build/Clipnest.app"
DEST="/Applications/Clipnest.app"
BUNDLE_ID="com.clipnest.app"

log() { printf '[dev-install.sh] %s\n' "$*"; }
fail() {
	printf '[dev-install.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" ||
	fail "signing identity \"$IDENTITY\" not found — run scripts/dev-cert.sh first"

log "Step 1/5: building"
"$REPO_ROOT/scripts/build.sh" >/dev/null || fail "scripts/build.sh failed — re-run it directly to see the log"
[ -d "$BUILT_APP" ] || fail "build.sh reported success but $BUILT_APP is missing"

log "Step 2/5: signing with \"$IDENTITY\""
# --deep is required: build.sh's archive export leaves the embedded
# ClipnestCore/KeyboardShortcuts frameworks linker-signed, and an outer
# signature over inconsistently-signed nested code fails --verify --deep.
codesign --force --deep --sign "$IDENTITY" "$BUILT_APP" ||
	fail "codesign failed — if this is errSecInternalComponent, re-run scripts/dev-cert.sh"
codesign --verify --deep --strict "$BUILT_APP" || fail "signature did not verify"

log "Step 3/5: quitting the running copy"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -f "Clipnest.app/Contents/MacOS/Clipnest" >/dev/null 2>&1 || true

log "Step 4/5: installing to $DEST"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST" || fail "could not copy into /Applications"
# lsregister so Spotlight/LaunchServices pick up the replaced bundle rather
# than caching the old one.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
	-f "$DEST" >/dev/null 2>&1 || true

log "Step 5/5: launching"
open -a "$DEST"

log "Installed $(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"
log "Designated requirement:"
codesign -d -r- "$DEST" 2>&1 | grep -i designated || true
