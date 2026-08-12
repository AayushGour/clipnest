#!/usr/bin/env bash
#
# scripts/package_dmg.sh — package build/Clipnest.app into a distributable
# Clipnest.dmg (plan task T37)
#
# Usage:
#   scripts/package_dmg.sh
#
# Input:  build/Clipnest.app  — ideally already signed + notarized + stapled
#                                by scripts/sign.sh + scripts/notarize.sh.
#                                This script will still run against an
#                                unsigned app for local testing, but the
#                                resulting .dmg won't pass Gatekeeper until
#                                the app inside is genuinely notarized.
# Output: build/Clipnest.dmg
#
# Prefers `create-dmg` (nicer drag-to-Applications window layout) if it's
# installed (brew install create-dmg); otherwise falls back to a plain
# hdiutil-built DMG with the same drag-to-Applications layout assembled by
# hand (an Applications symlink alongside the app).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="Clipnest.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
DMG_PATH="$BUILD_DIR/Clipnest.dmg"
VOLUME_NAME="Clipnest"

log() { printf '[package_dmg.sh] %s\n' "$*"; }
fail() {
	printf '[package_dmg.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

[ -d "$APP_PATH" ] || fail "$APP_PATH not found — run scripts/build.sh (and ideally sign.sh + notarize.sh) first"

rm -f "$DMG_PATH"

STAGING_DIR="$(mktemp -d "$BUILD_DIR/dmg-staging.XXXXXX")"
cleanup() { rm -rf "${STAGING_DIR:?}"; }
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME" || fail "failed to stage $APP_PATH for packaging"

if command -v create-dmg >/dev/null 2>&1; then
	log "create-dmg found — building $DMG_PATH with a drag-to-Applications window layout"
	# --skip-jenkins: skips create-dmg's Finder-prettifying AppleScript
	# (window position/icon layout cosmetics), which needs interactive
	# Automation permission to control Finder and otherwise hangs in a
	# non-interactive/CI shell with no way to grant that prompt. create-dmg's
	# own --help calls this flag out as "useful in Sandbox and non-GUI
	# environments" — exactly this script's expected run context. The
	# --window-pos/--window-size/--icon/--app-drop-link layout options above
	# are kept so a human running this from an interactive Terminal with
	# Automation permission already granted still gets the full fancy
	# window; --skip-jenkins only skips the AppleScript, not the DMG's
	# actual drag-to-Applications structure (the .app + Applications symlink
	# are still both present either way).
	if ! create-dmg \
		--volname "$VOLUME_NAME" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$APP_NAME" 165 190 \
		--hide-extension "$APP_NAME" \
		--app-drop-link 495 190 \
		--skip-jenkins \
		--overwrite \
		"$DMG_PATH" \
		"$STAGING_DIR"; then
		fail "create-dmg failed — see the output above"
	fi
else
	log "create-dmg not found — install it for a nicer window layout: brew install create-dmg"
	log "falling back to a plain hdiutil-built DMG (still drag-to-Applications)"

	ln -s /Applications "$STAGING_DIR/Applications" || fail "failed to create the Applications symlink"

	if ! hdiutil create \
		-volname "$VOLUME_NAME" \
		-srcfolder "$STAGING_DIR" \
		-ov -format UDZO \
		"$DMG_PATH"; then
		fail "hdiutil create failed"
	fi
fi

[ -f "$DMG_PATH" ] || fail "packaging finished but $DMG_PATH is missing — this should be unreachable"

log "Done — $DMG_PATH is ready"
log "Gatekeeper assessment (spctl) — expect a pass only once the app inside is genuinely notarized+stapled:"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" || true
