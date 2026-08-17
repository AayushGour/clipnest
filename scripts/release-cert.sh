#!/usr/bin/env bash
#
# scripts/release-cert.sh — generate the ONE stable signing key that every
# published Clipnest release is signed with.
#
# Why this exists: CI builds with CODE_SIGNING_ALLOWED=NO, so without a cert
# each release DMG is ad-hoc signed and its designated code requirement is
# pinned to that build's cdhash. macOS TCC stores that requirement when a user
# grants Accessibility — so every update invalidated the grant, and the user
# had to remove and re-add Clipnest in System Settings (toggling it off/on
# does not work). Signing every release with one long-lived certificate makes
# the requirement
#
#   identifier "com.clipnest.app" and certificate root = H"<stable hash>"
#
# which contains no cdhash and therefore survives updates. Users grant once.
#
# This is NOT a Developer ID and does NOT enable notarization — Gatekeeper
# still treats a browser-downloaded .dmg as an unidentified developer. That is
# fine for the supported install path: `curl` never sets com.apple.quarantine,
# so scripts/install.sh installs launch cleanly (see that script's header).
#
# Run this ONCE, ever. Re-running produces a DIFFERENT key, which would break
# every existing user's Accessibility grant exactly like ad-hoc signing did.
# Keep the .p12 somewhere safe; it is the only copy.
#
# Usage:
#   scripts/release-cert.sh [output-dir]      # defaults to ./release-cert
#
# Then add the three printed values as GitHub repo secrets
# (Settings -> Secrets and variables -> Actions):
#   MACOS_CERTIFICATE_P12_BASE64
#   MACOS_CERTIFICATE_PASSWORD
#   CODESIGN_IDENTITY
#
set -euo pipefail

IDENTITY="${CLIPNEST_RELEASE_IDENTITY:-Clipnest Release}"
OUT_DIR="${1:-./release-cert}"

log() { printf '[release-cert.sh] %s\n' "$*"; }
fail() {
	printf '[release-cert.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

command -v openssl >/dev/null 2>&1 || fail "openssl not found"

if [ -e "$OUT_DIR" ]; then
	fail "$OUT_DIR already exists — refusing to overwrite an existing release key. Re-running this script mints a DIFFERENT key and would break every existing user's Accessibility grant. Delete it deliberately if you really mean to rotate."
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

log "Generating the release signing certificate (valid 10 years)"
# extendedKeyUsage=codeSigning is what makes codesign recognize this as a
# signing identity at all; without it the key imports and is then invisible.
openssl req -x509 -newkey rsa:2048 \
	-keyout "$OUT_DIR/key.pem" -out "$OUT_DIR/cert.pem" \
	-days 3650 -nodes \
	-subj "/CN=$IDENTITY/O=Clipnest/C=US" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 ||
	fail "openssl could not generate the certificate"

# -legacy: macOS's Security framework cannot import PKCS#12 files that use
# OpenSSL 3's default AES-256-CBC/PBKDF2 encryption, which is what the CI
# runner's `security import` step would choke on.
openssl pkcs12 -export -legacy \
	-out "$OUT_DIR/release.p12" -inkey "$OUT_DIR/key.pem" -in "$OUT_DIR/cert.pem" \
	-name "$IDENTITY" -passout "pass:$PASSWORD" >/dev/null 2>&1 ||
	fail "openssl could not build the PKCS#12 bundle"

chmod 600 "$OUT_DIR"/*
base64 -i "$OUT_DIR/release.p12" | tr -d '\n' > "$OUT_DIR/release.p12.base64"

log "Done. Files are in $OUT_DIR (keep these private and backed up)."
echo
echo "Add these as GitHub repo secrets — Settings > Secrets and variables > Actions:"
echo
echo "  CODESIGN_IDENTITY             $IDENTITY"
echo "  MACOS_CERTIFICATE_PASSWORD    $PASSWORD"
echo "  MACOS_CERTIFICATE_P12_BASE64  (contents of $OUT_DIR/release.p12.base64)"
echo
echo "Or set them non-interactively with the gh CLI:"
echo
echo "  gh secret set CODESIGN_IDENTITY --body \"$IDENTITY\""
echo "  gh secret set MACOS_CERTIFICATE_PASSWORD --body \"$PASSWORD\""
echo "  gh secret set MACOS_CERTIFICATE_P12_BASE64 < $OUT_DIR/release.p12.base64"
