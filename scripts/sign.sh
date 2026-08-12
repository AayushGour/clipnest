#!/usr/bin/env bash
#
# scripts/sign.sh — Developer ID codesign step (plan task T36)
#
# Codesigns build/Clipnest.app (produced by scripts/build.sh) with a real
# Developer ID Application certificate, ready for scripts/notarize.sh.
#
# Requires a Developer ID Application certificate already present in your
# keychain, issued from YOUR OWN Apple Developer account — this script
# cannot create or supply one. List installed identities with:
#   security find-identity -v -p codesigning
#
# The identity string is NEVER hardcoded in this script or committed
# anywhere. Pass it as the first argument, or export it as CODESIGN_IDENTITY
# before running:
#
#   scripts/sign.sh "Developer ID Application: Your Name (TEAMID)"
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/sign.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/Clipnest.app"

log() { printf '[sign.sh] %s\n' "$*"; }
fail() {
	printf '[sign.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

IDENTITY="${1:-${CODESIGN_IDENTITY:-}}"

if [ -z "$IDENTITY" ]; then
	fail "no signing identity provided. Usage: scripts/sign.sh \"Developer ID Application: <name> (<TEAMID>)\" (or set \$CODESIGN_IDENTITY). List installed identities with: security find-identity -v -p codesigning"
fi

[ -d "$APP_PATH" ] || fail "$APP_PATH not found — run scripts/build.sh first"
command -v codesign >/dev/null 2>&1 || fail "codesign not found (should ship with the Xcode Command Line Tools)"

log "Signing $APP_PATH"
if ! codesign --deep --force --options runtime --sign "$IDENTITY" "$APP_PATH"; then
	fail "codesign failed — confirm the identity is installed: security find-identity -v -p codesigning"
fi

log "Verifying signature"
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH"; then
	fail "codesign --verify failed after signing — the app is not validly signed"
fi

log "Gatekeeper assessment (spctl) — expect 'rejected' here until scripts/notarize.sh has run"
spctl --assess --type execute --verbose=4 "$APP_PATH" || true

log "Done — $APP_PATH is signed. Next: scripts/notarize.sh"
