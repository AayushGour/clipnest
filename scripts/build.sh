#!/usr/bin/env bash
#
# scripts/build.sh — Clipnest release build (plan task T35)
#
# Generates the Xcode project (xcodegen), archives a Release build, and
# exports a runnable Clipnest.app into build/. This script never requires a
# Developer ID signing identity to succeed: the archive step explicitly
# disables signing enforcement (CODE_SIGNING_ALLOWED=NO / _REQUIRED=NO),
# matching the pattern used elsewhere in this project for signing-less
# builds. Real Developer ID signing is scripts/sign.sh's job (T36), not
# this script's — this script only has to produce a valid, runnable .app.
#
# Usage:
#   scripts/build.sh
#
# Output:
#   build/Clipnest.xcarchive   the raw xcodebuild archive
#   build/Clipnest.app         the exported app bundle, ready for scripts/sign.sh
#
# Env vars (all optional — never required, never hardcoded here):
#   DEVELOPMENT_TEAM   Apple Developer Team ID (10 chars). If set, this
#                       script generates build/ExportOptions.plist and uses
#                       `xcodebuild -exportArchive` (method: developer-id)
#                       to export the app instead of copying it straight out
#                       of the archive. Same variable name XcodeGen expands
#                       into ClipnestApp/project.yml's Release DEVELOPMENT_TEAM
#                       setting, so setting it once covers both.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PROJECT_DIR="$REPO_ROOT/ClipnestApp"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Clipnest.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
APP_NAME="Clipnest.app"
SCHEME="ClipnestApp"
PROJECT_PATH="$APP_PROJECT_DIR/ClipnestApp.xcodeproj"

log() { printf '[build.sh] %s\n' "$*"; }
fail() {
	printf '[build.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found — install with: brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — install Xcode (or the Command Line Tools) first"

mkdir -p "$BUILD_DIR"

log "Step 1/3: xcodegen generate (in $APP_PROJECT_DIR)"
if ! (cd "$APP_PROJECT_DIR" && xcodegen generate); then
	fail "xcodegen generate failed — check ClipnestApp/project.yml"
fi
[ -d "$PROJECT_PATH" ] || fail "xcodegen reported success but $PROJECT_PATH is missing"

log "Step 2/3: xcodebuild archive (Release)"
rm -rf "${ARCHIVE_PATH:?}"
if ! xcodebuild \
	-project "$PROJECT_PATH" \
	-scheme "$SCHEME" \
	-configuration Release \
	archive \
	-archivePath "$ARCHIVE_PATH" \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO; then
	fail "xcodebuild archive failed — see the build log above"
fi
[ -d "$ARCHIVE_PATH" ] || fail "archive step reported success but $ARCHIVE_PATH is missing"

ARCHIVE_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
[ -d "$ARCHIVE_APP_PATH" ] || fail "archive produced no $APP_NAME at $ARCHIVE_APP_PATH"

log "Step 3/3: export $APP_NAME from the archive"
rm -rf "${BUILD_DIR:?}/$APP_NAME"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
	log "DEVELOPMENT_TEAM is set — exporting via xcodebuild -exportArchive (method: developer-id)"

	cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
PLIST

	rm -rf "${EXPORT_DIR:?}"
	if ! xcodebuild -exportArchive \
		-archivePath "$ARCHIVE_PATH" \
		-exportPath "$EXPORT_DIR" \
		-exportOptionsPlist "$EXPORT_OPTIONS_PLIST"; then
		fail "xcodebuild -exportArchive failed — see the build log above"
	fi
	[ -d "$EXPORT_DIR/$APP_NAME" ] || fail "exportArchive reported success but $EXPORT_DIR/$APP_NAME is missing"
	cp -R "$EXPORT_DIR/$APP_NAME" "$BUILD_DIR/$APP_NAME" || fail "failed to copy the exported app into $BUILD_DIR"
else
	log "DEVELOPMENT_TEAM not set — copying $APP_NAME directly from the archive (no export options plist)"
	log "(set DEVELOPMENT_TEAM for a real Developer ID export instead; scripts/sign.sh does the actual signing either way)"
	cp -R "$ARCHIVE_APP_PATH" "$BUILD_DIR/$APP_NAME" || fail "failed to copy $APP_NAME out of the archive"
fi

[ -d "$BUILD_DIR/$APP_NAME" ] || fail "build finished but $BUILD_DIR/$APP_NAME is missing — this should be unreachable"

log "Done — $BUILD_DIR/$APP_NAME is ready. Next: scripts/sign.sh"
