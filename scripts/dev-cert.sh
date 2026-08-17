#!/usr/bin/env bash
#
# scripts/dev-cert.sh — create the local, self-signed code-signing identity
# that keeps macOS permissions attached to Clipnest across rebuilds.
#
# The problem this solves: an ad-hoc-signed app (what scripts/build.sh
# produces on its own) has a designated code requirement pinned to the
# binary's cdhash. TCC stores that requirement when you grant Accessibility,
# so the NEXT build — different bytes, different cdhash — no longer matches.
# System Settings keeps showing Clipnest listed and switched ON while
# AXIsProcessTrusted() returns false, and toggling the switch does not fix it;
# only removing and re-adding the entry does.
#
# Signing with a stable certificate instead produces:
#
#   designated => identifier "com.clipnest.app" and certificate root = H"..."
#
# — no cdhash, so the grant survives every rebuild signed by the same cert.
#
# This is for LOCAL development only. It is not a Developer ID, it is not
# notarized, and it must never be used for anything you distribute — see
# scripts/sign.sh + scripts/notarize.sh for the real release path.
#
# Usage:
#   scripts/dev-cert.sh            # create it (idempotent — safe to re-run)
#
# Env vars:
#   CLIPNEST_DEV_IDENTITY   Common Name of the identity. Default below.
#                           Must match scripts/dev-install.sh.
#
set -euo pipefail

IDENTITY="${CLIPNEST_DEV_IDENTITY:-Clipnest Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

log() { printf '[dev-cert.sh] %s\n' "$*"; }
fail() {
	printf '[dev-cert.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

if security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
	log "\"$IDENTITY\" already exists and is valid — nothing to do."
	log "Verify with: security find-identity -v -p codesigning"
	exit 0
fi

command -v openssl >/dev/null 2>&1 || fail "openssl not found"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Step 1/4: generating a self-signed code-signing certificate"
# extendedKeyUsage=codeSigning is what makes `codesign`/`find-identity -p
# codesigning` recognize this as a signing identity at all; without it the
# key imports fine and is then invisible to codesign.
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
	-days 3650 -nodes \
	-subj "/CN=$IDENTITY/O=Clipnest/C=US" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 ||
	fail "openssl could not generate the certificate"

# -legacy: macOS's Security framework cannot import PKCS#12 files that use
# OpenSSL 3's default AES-256-CBC/PBKDF2 encryption.
openssl pkcs12 -export -legacy \
	-out "$WORK/cert.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	-name "$IDENTITY" -passout pass:clipnest >/dev/null 2>&1 ||
	fail "openssl could not build the PKCS#12 bundle"

log "Step 2/4: importing into the login keychain"
# -T /usr/bin/codesign puts codesign on the private key's ACL; -A additionally
# allows any application, so a plain `codesign` run doesn't stall on a
# keychain access dialog.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P clipnest -T /usr/bin/codesign -A ||
	fail "security import failed"

log "Step 3/4: trusting it for code signing (macOS may ask for your password)"
# Without a trust setting the identity imports but reports
# CSSMERR_TP_NOT_TRUSTED and `find-identity -v` refuses to list it. User
# trust domain only — this never touches the system trust store.
security add-trusted-cert -p codeSign "$WORK/cert.pem" ||
	fail "security add-trusted-cert failed"

log "Step 4/4: granting codesign access to the private key"
# Separate from the import ACL above: modern macOS also gates key use behind
# a partition list, and codesign fails with errSecInternalComponent without
# this even when the ACL allows it.
security set-key-partition-list \
	-S apple-tool:,apple:,codesign: -s -l "$IDENTITY" >/dev/null 2>&1 ||
	fail "security set-key-partition-list failed"

security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" ||
	fail "identity still not valid after setup — see the output above"

log "Done — \"$IDENTITY\" is ready. Next: scripts/dev-install.sh"
