#!/usr/bin/env bash
#
# scripts/notarize.sh — notarize + staple the signed Clipnest.app (plan task T36)
#
# ONE-TIME SETUP (run this yourself, once, on the machine you release from —
# it stores credentials in your OWN login keychain, never in this repo):
#
#   xcrun notarytool store-credentials "<profile-name>" \
#     --apple-id "<your-apple-id>" \
#     --team-id "<TEAMID>" \
#     --password "<app-specific-password>"
#
# Create an app-specific password at https://appleid.apple.com if you don't
# have one. After store-credentials has run once, this script only ever
# needs the profile NAME you chose above — never your Apple ID, Team ID, or
# password again.
#
# The keychain profile name is NEVER hardcoded in this script or committed
# anywhere. Pass it as the first argument, or export it as NOTARY_PROFILE
# before running:
#
#   scripts/notarize.sh "<keychain-profile-name>"
#   NOTARY_PROFILE="<keychain-profile-name>" scripts/notarize.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/Clipnest.app"
ZIP_PATH="$REPO_ROOT/build/Clipnest.zip"

log() { printf '[notarize.sh] %s\n' "$*"; }
fail() {
	printf '[notarize.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

PROFILE="${1:-${NOTARY_PROFILE:-}}"

if [ -z "$PROFILE" ]; then
	fail "no keychain profile name provided. Usage: scripts/notarize.sh \"<profile-name>\" (or set \$NOTARY_PROFILE). See this script's header comment for the one-time 'xcrun notarytool store-credentials' setup."
fi

[ -d "$APP_PATH" ] || fail "$APP_PATH not found — run scripts/build.sh and scripts/sign.sh first"
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found (requires Xcode / the Command Line Tools)"

log "Verifying $APP_PATH is signed before submitting"
if ! codesign --verify --deep --strict "$APP_PATH"; then
	fail "$APP_PATH does not have a valid signature — run scripts/sign.sh first"
fi

log "Zipping $APP_PATH -> $ZIP_PATH"
rm -f "$ZIP_PATH"
if ! ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"; then
	fail "failed to zip $APP_PATH for submission"
fi

log "Submitting to Apple's notary service (profile: $PROFILE) — this can take several minutes"
if ! xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait; then
	fail "notarytool submit failed — see the output above for the reason (run 'xcrun notarytool log <submission-id> --keychain-profile \"$PROFILE\"' for full details)"
fi

log "Notarization succeeded — stapling the ticket to $APP_PATH"
if ! xcrun stapler staple "$APP_PATH"; then
	fail "stapler staple failed"
fi

log "Done — $APP_PATH is signed, notarized, and stapled. Next: scripts/package_dmg.sh"
