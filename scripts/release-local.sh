#!/usr/bin/env bash
#
# scripts/release-local.sh — build and publish a full Clipnest release from
# this machine. The local equivalent of .github/workflows/release.yml, for
# when GitHub Actions minutes are unavailable.
#
# It reproduces that workflow's guarantees, not just its commands. Each one
# below is load-bearing and its failure mode is SILENT, which is why it is
# asserted here rather than left to care:
#
#   * Signs with the "Clipnest Release" certificate (scripts/release-cert.sh),
#     never a dev identity. That certificate's designated requirement pins to
#     a stable cert root instead of a per-build cdhash — it is the ONLY thing
#     keeping users' Accessibility grants alive across updates. Signing with
#     "Clipnest Local Dev" (scripts/dev-cert.sh) would silently force every
#     existing user to remove and re-add Clipnest in System Settings. The cert
#     is imported into a TEMPORARY keychain (mirroring release.yml's CI step)
#     and cleaned up on exit via trap — the login keychain is never touched.
#     Before the slow build, this script asserts the identity actually signs
#     something; after signing, it asserts the app's designated requirement
#     contains the expected stable certificate root and NO cdhash, and prints
#     it.
#
#   * Notarization is SKIPPED, deliberately, not attempted. "Clipnest Release"
#     is self-signed, not a Developer ID — Apple's notary service only
#     accepts Developer ID-signed submissions, full stop. This is fine for
#     the supported install path: scripts/install.sh and scripts/update.sh
#     fetch with `curl`, which never sets com.apple.quarantine — and it's
#     exactly that flag (not the code signature) that triggers Gatekeeper's
#     notarization check. See install.sh's header for the full reasoning.
#
#   * The release is staged as a DRAFT: the .dmg and its .sha256 are both
#     uploaded and CONFIRMED present on the draft before it is published.
#     scripts/install.sh and scripts/update.sh resolve /releases/latest and
#     FAIL CLOSED (REQUIRE_CHECKSUM=true by default) when the .sha256 asset
#     is missing. If a .dmg ever became visible on a published release before
#     its checksum, every install/update in that window would abort. Draft-
#     first eliminates the window entirely — nothing is visible at
#     /releases/latest until both assets are already there and this script
#     flips --draft=false as the very last step.
#
#   * An already-PUBLISHED v$VERSION is refused outright. Assets on a live
#     release are being served to real users right now; clobbering one mid-
#     replacement would serve 404s. Bump MARKETING_VERSION in
#     ClipnestApp/project.yml first (this script will never do that for you).
#
#   * The tag lands on a commit GitHub actually has. Preflight requires a
#     clean working tree and HEAD pushed to origin/main — otherwise
#     `gh release create --target <sha>` either tags a commit GitHub has
#     never seen, or silently misrepresents what was actually built. Per this
#     repo's convention, the USER commits — this script never runs `git
#     commit`, `git tag`, or `git push`.
#
#   * The checksum's format matches exactly what scripts/install.sh and
#     scripts/update.sh parse (`grep -oE '[0-9a-fA-F]{64}'` against the
#     asset's raw text): a `shasum -a 256`-shaped line, `<hash>  <filename>`,
#     published as its own release asset named `<dmg-basename>.sha256` — the
#     identical shape release.yml already produces.
#
#   * Quality gates run BEFORE the slow build and FAIL the release on any
#     violation: swift-format lint (--strict, matching release.yml's exact
#     two invocations), `swift test` (Core), and — an intentional addition
#     release.yml does NOT do — `xcodebuild test` for the App target. A local
#     release has no CI safety net, so this script adds one. Note:
#     xcodebuild's XCTest harness prints a decoy "Executed 0 tests, with 0
#     failures" line for its (empty) XCTest wrapper bundle — that is NOT the
#     success signal. This script asserts on the real Swift Testing summary
#     line ("Test run with N tests in M suites passed") and the final
#     "** TEST SUCCEEDED **" marker, not on exit code alone.
#
# Usage:
#   scripts/release-local.sh [options]
#
#   --dry-run      Run every preflight check, quality gate, and the full
#                  build/sign/package pipeline. Touches NO remote state —
#                  stops right after the .dmg + .sha256 exist locally, before
#                  any `gh` call that could create/upload/publish anything.
#   --keep-draft   Do everything through uploading + verifying both assets on
#                  the draft, then STOP — do not publish. Useful for
#                  inspecting a release before it goes live. Prints the exact
#                  command to publish it when you're ready.
#   --reuse        If build/Clipnest-$VERSION.dmg and its .sha256 already
#                  exist (from a previous run this session), verify them
#                  in place instead of rebuilding — skips quality gates, cert
#                  import, build.sh, sign.sh, and package_dmg.sh entirely.
#                  Safe against the "reused artifact ships under the wrong
#                  version" hazard by construction: the artifact filename is
#                  version-scoped, so a version bump can never accidentally
#                  reuse a stale build — it just rebuilds fresh instead.
#                  Without --reuse, every run rebuilds from scratch.
#   -h, --help     This message.
#
# Required (checked in preflight, not assumed):
#   release-cert/cert.pem + release-cert/key.pem   from scripts/release-cert.sh
#                                                    (run once, ever — see its
#                                                    header). Never regenerate
#                                                    these to "fix" a release;
#                                                    a new key breaks every
#                                                    existing user's
#                                                    Accessibility grant.
#   A clean working tree, with HEAD already pushed to origin/main.
#   gh, authenticated (`gh auth status`), with access to this repo.
#   xcodegen, create-dmg (brew install xcodegen create-dmg), swift-format
#   (ships with the Swift 6 toolchain), a working Xcode / Command Line Tools.
#
# Optional environment:
#   CLIPNEST_RELEASE_IDENTITY   Common Name of the release signing identity.
#                                Must match scripts/release-cert.sh (same
#                                variable name). Default: "Clipnest Release".
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_PROJECT_DIR="$REPO_ROOT/ClipnestApp"
PROJECT_YML="$APP_PROJECT_DIR/project.yml"
PROJECT_PATH="$APP_PROJECT_DIR/ClipnestApp.xcodeproj"
SCHEME="ClipnestApp"
BUILD_DIR="$REPO_ROOT/build"
APP_NAME="Clipnest.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
RELEASE_CERT_DIR="$REPO_ROOT/release-cert"
IDENTITY="${CLIPNEST_RELEASE_IDENTITY:-Clipnest Release}"

# Matches the constant hardcoded identically in scripts/install.sh and
# scripts/update.sh — this is the one repo that gets released, so it is not
# meant to be configurable; kept as a named constant rather than repeated
# inline so a future rename only has to happen in one place in THIS file.
REPO_SLUG="AayushGour/clipnest"
GITHUB_BRANCH="main"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  # `\|` alternation inside `\(...\)` is a GNU-sed extension to BRE, not
  # POSIX — macOS's shipped BSD sed silently fails to strip anything with it
  # (confirmed empirically). `[[:space:]]?` under `-E` (POSIX ERE) works on
  # both.
  sed -n '2,95p' "$REPO_ROOT/scripts/release-local.sh" | sed -E 's/^#[[:space:]]?//'
}

DRY_RUN=0
KEEP_DRAFT=0
REUSE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --keep-draft) KEEP_DRAFT=1 ;;
    --reuse)      REUSE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown option: $arg (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- workdir --
# Everything sensitive (the throwaway p12, its keychain, a scratch codesign
# test binary) lives here and nowhere else, cleaned up unconditionally on
# exit — success, --dry-run stop, or a die() partway through.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipnest-release.XXXXXX")"
KEYCHAIN="$WORK_DIR/release-signing.keychain-db"
KEYCHAIN_CREATED=0
ORIGINAL_KEYCHAINS=()
REUSE_MOUNT=""

cleanup() {
  if [ -n "$REUSE_MOUNT" ]; then
    hdiutil detach "$REUSE_MOUNT" -quiet 2>/dev/null || true
  fi
  if [ "$KEYCHAIN_CREATED" = 1 ]; then
    # Restore the search list BEFORE deleting the temp keychain — deleting it
    # first would leave a dangling entry in the search list until restored.
    security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"} >/dev/null 2>&1 || true
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight --
# Everything that can be known up front is checked here, because the
# expensive failure is discovering a missing credential after 5+ minutes of
# archiving + testing.
log "preflight"

[ "$(uname -s)" = "Darwin" ] || die "must run on macOS"

for tool in xcodegen xcodebuild swift codesign security openssl shasum gh git cc hdiutil; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
command -v create-dmg >/dev/null 2>&1 || warn "create-dmg not found — scripts/package_dmg.sh will fall back to a plain hdiutil DMG (still correct, less pretty). brew install create-dmg to fix."

[ -f "$PROJECT_YML" ] || die "not a clipnest checkout — $PROJECT_YML missing"

# Same extraction release.yml's `check` job uses — one source of truth for
# what "the version" means, so this script can never disagree with CI about it.
VERSION="$(grep -E '^[[:space:]]*MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from $PROJECT_YML"

# NOTE: `\s` is a GNU-sed/PCRE regex escape, not POSIX ERE — macOS's shipped
# `sed -E` does NOT treat it as whitespace (unlike its `grep -E`, confirmed
# empirically to differ from its own `sed -E` here), so `[[:space:]]` is used
# throughout this file instead of `\s`, in both grep and sed, for real
# portability rather than relying on either tool's undefined behavior.
BUNDLE_ID="$(grep -E '^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:' "$PROJECT_YML" | head -1 | sed -E 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*//' | tr -d '[:space:]')"
[ -n "$BUNDLE_ID" ] || die "could not read PRODUCT_BUNDLE_IDENTIFIER from $PROJECT_YML"

log "releasing Clipnest v$VERSION ($BUNDLE_ID)"

[ -f "$RELEASE_CERT_DIR/cert.pem" ] && [ -f "$RELEASE_CERT_DIR/key.pem" ] || die "release signing key not found at $RELEASE_CERT_DIR/{cert.pem,key.pem}.
  This is the ONE stable key every published Clipnest release must be signed
  with (see scripts/release-cert.sh's header). It cannot be regenerated here
  — re-running scripts/release-cert.sh mints a DIFFERENT key and breaks every
  existing user's Accessibility grant. Restore your archived copy into
  $RELEASE_CERT_DIR/ (cert.pem + key.pem, unencrypted -nodes PEM) before
  retrying."

# Refuse to touch a dirty tree or a commit GitHub has never seen — the tag
# this script creates has to land on a real, pushed commit, always, even
# under --dry-run (this is a local-only git check, not a remote mutation, so
# it belongs in "every preflight" regardless of --dry-run).
[ -z "$(git status --porcelain)" ] || die "working tree is not clean. Per this repo's convention YOU commit, this script never will — commit or stash your changes first, then re-run."
LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git ls-remote origin "refs/heads/$GITHUB_BRANCH" | awk '{print $1}')"
[ -n "$REMOTE_SHA" ] || die "could not read origin/$GITHUB_BRANCH via git ls-remote — check your network/remote config"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || die "HEAD ($LOCAL_SHA) is not pushed to origin/$GITHUB_BRANCH (origin/$GITHUB_BRANCH is $REMOTE_SHA) — push first: git push origin $GITHUB_BRANCH"
log "HEAD ($LOCAL_SHA) matches origin/$GITHUB_BRANCH — safe to tag"

DMG_OUT="$BUILD_DIR/Clipnest-${VERSION}.dmg"
CHECKSUM_OUT="${DMG_OUT}.sha256"

# gh calls (auth check + the already-published guard) are gated on
# DRY_RUN==0, same as release-local scripts before this one: --dry-run means
# "build everything, touch NOTHING remote" — not even a read call — so it
# also has to work fully offline and never cares whether v$VERSION happens
# to already be published.
RELEASE_EXISTS=0
if [ "$DRY_RUN" = 0 ]; then
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

  # Refuse to touch an already-PUBLISHED release. This has to distinguish a
  # genuine "not found" (release doesn't exist yet — fine, we'll create it)
  # from any other gh/API failure (e.g. a rate limit) — the unauthenticated
  # GitHub API rate limit was hit earlier today, and `gh` uses an
  # authenticated token so it's a much higher ceiling, but a failure here
  # must never be silently treated as "so it must not exist yet".
  REL_ERR="$WORK_DIR/release-view.err"
  set +e
  REL_STATE="$(gh release view "v$VERSION" --repo "$REPO_SLUG" --json isDraft -q .isDraft 2>"$REL_ERR")"
  REL_RC=$?
  set -e
  if [ "$REL_RC" -eq 0 ]; then
    if [ "$REL_STATE" = "false" ]; then
      die "v$VERSION is already PUBLISHED on $REPO_SLUG. Assets on it are being served to real users right now — this script refuses to touch a live release.
  Bump MARKETING_VERSION in ClipnestApp/project.yml (commit + push it — this
  script never will), then re-run."
    fi
    log "found an existing DRAFT release v$VERSION on $REPO_SLUG — will reuse it"
    RELEASE_EXISTS=1
  else
    REL_ERR_MSG="$(cat "$REL_ERR" 2>/dev/null || true)"
    if printf '%s' "$REL_ERR_MSG" | grep -qiF "release not found"; then
      log "no existing release v$VERSION on $REPO_SLUG — will create a draft"
    else
      die "could not determine whether v$VERSION already exists on $REPO_SLUG: $REL_ERR_MSG
  If this looks like a rate limit or auth issue, check: gh auth status
  Do not proceed until this is resolved — publishing blind onto a release
  this script couldn't actually inspect is exactly the mistake guarantee #3
  in this file's header exists to prevent."
    fi
  fi
fi

# ------------------------------------------------------ reuse short-circuit --
REUSE_HIT=0
if [ "$REUSE" = 1 ] && [ -f "$DMG_OUT" ] && [ -f "$CHECKSUM_OUT" ]; then
  REUSE_HIT=1
fi

if [ "$REUSE_HIT" = 1 ]; then
  log "--reuse: found $DMG_OUT from a previous run — verifying it instead of rebuilding"

  RECORDED_SHA="$(awk '{print $1}' "$CHECKSUM_OUT")"
  ACTUAL_SHA="$(shasum -a 256 "$DMG_OUT" | awk '{print $1}')"
  [ "$RECORDED_SHA" = "$ACTUAL_SHA" ] || die "--reuse: $CHECKSUM_OUT does not match $DMG_OUT's actual bytes (recorded $RECORDED_SHA, actual $ACTUAL_SHA) — re-run without --reuse to rebuild clean."

  ATTACH_OUT="$(hdiutil attach "$DMG_OUT" -nobrowse -noverify -noautoopen)"
  REUSE_MOUNT="$(printf '%s' "$ATTACH_OUT" | grep -oE '/Volumes/.+$' | tail -1 || true)"
  [ -n "$REUSE_MOUNT" ] && [ -d "$REUSE_MOUNT/$APP_NAME" ] || die "--reuse: mounted $DMG_OUT but could not find $APP_NAME inside it"

  DR_OUTPUT="$(codesign -d -r- "$REUSE_MOUNT/$APP_NAME" 2>&1)" || true
  hdiutil detach "$REUSE_MOUNT" -quiet 2>/dev/null || true
  REUSE_MOUNT=""

  printf '%s\n' "$DR_OUTPUT" | grep -qF 'certificate root = H"' || die "--reuse: $DMG_OUT's designated requirement has no stable certificate root — this is not a release-signed build. Re-run without --reuse.
$DR_OUTPUT"
  printf '%s\n' "$DR_OUTPUT" | grep -qF 'cdhash H"' && die "--reuse: $DMG_OUT's designated requirement pins a cdhash instead of the stable certificate root — re-run without --reuse.
$DR_OUTPUT"
  log "--reuse: verified $DMG_OUT is release-signed correctly:"
  printf '%s\n' "$DR_OUTPUT"
else
  [ "$REUSE" = 1 ] && log "--reuse requested but no matching v$VERSION artifact found at $DMG_OUT — building fresh"

  # ------------------------------------------------------------ quality gates --
  # Fail the release on any violation, run BEFORE the slow build.
  log "quality gate: swift format lint --strict (Core: Sources Tests)"
  if ! swift format lint --recursive --strict Sources Tests >"$WORK_DIR/lint-core.log" 2>&1; then
    cat "$WORK_DIR/lint-core.log" >&2
    die "swift format lint failed on Sources/Tests"
  fi

  log "quality gate: swift format lint --strict (App: ClipnestApp/Sources)"
  # ClipnestApp/Tests is deliberately NOT linted here, matching release.yml —
  # there is one known pre-existing violation at
  # ClipnestApp/Tests/ClipnestAppTests/HotkeyManagerTests.swift:25 that is out
  # of scope for a release run; do not lint or "fix" it here.
  if ! swift format lint --recursive --strict ClipnestApp/Sources >"$WORK_DIR/lint-app.log" 2>&1; then
    cat "$WORK_DIR/lint-app.log" >&2
    die "swift format lint failed on ClipnestApp/Sources"
  fi

  log "quality gate: swift test (Core)"
  if ! swift test >"$WORK_DIR/swift-test.log" 2>&1; then
    cat "$WORK_DIR/swift-test.log" >&2
    die "swift test failed"
  fi
  SWIFT_TEST_SUMMARY="$(grep -Eo 'Test run with [0-9]+ tests? in [0-9]+ suites? passed[^.]*' "$WORK_DIR/swift-test.log" | tail -1 || true)"
  [ -n "$SWIFT_TEST_SUMMARY" ] || die "swift test exited 0 but no Swift Testing summary line was found in its output — not trusting exit code alone. Log: $WORK_DIR/swift-test.log"
  log "swift test passed: $SWIFT_TEST_SUMMARY"

  log "quality gate: xcodebuild test (App target — deliberate improvement over release.yml, which does not run this; a local release has no CI safety net)"
  if ! (cd "$APP_PROJECT_DIR" && xcodegen generate) >"$WORK_DIR/xcodegen.log" 2>&1; then
    cat "$WORK_DIR/xcodegen.log" >&2
    die "xcodegen generate failed"
  fi
  if ! xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    >"$WORK_DIR/xcodebuild-test.log" 2>&1
  then
    tail -150 "$WORK_DIR/xcodebuild-test.log" >&2
    die "xcodebuild test failed — full log was at $WORK_DIR/xcodebuild-test.log (deleted on exit; re-run the command above directly to reproduce)"
  fi
  # The XCTest harness prints a decoy "Executed 0 tests, with 0 failures" line
  # for its own empty wrapper bundle — do NOT treat that as either signal.
  # The real success markers are "** TEST SUCCEEDED **" and the Swift Testing
  # summary line; require BOTH, not exit code alone.
  grep -q '\*\* TEST SUCCEEDED \*\*' "$WORK_DIR/xcodebuild-test.log" \
    || die "xcodebuild test exited 0 but never printed '** TEST SUCCEEDED **' — treating as a failure"
  XC_TEST_SUMMARY="$(grep -Eo 'Test run with [0-9]+ tests? in [0-9]+ suites? passed[^.]*' "$WORK_DIR/xcodebuild-test.log" | tail -1 || true)"
  [ -n "$XC_TEST_SUMMARY" ] || die "xcodebuild test printed '** TEST SUCCEEDED **' but no Swift Testing summary line was found — this is exactly the 'Executed 0 tests' trap (a passing exit code with nothing actually tested). Log: $WORK_DIR/xcodebuild-test.log"
  log "xcodebuild test passed: $XC_TEST_SUMMARY"

  # --------------------------------------------------------------- cert setup --
  # Import the release cert into a TEMPORARY keychain (never the login
  # keychain) and prove it can actually sign something, before spending 2-5
  # minutes on the archive build below.
  log "importing \"$IDENTITY\" into a temporary keychain"

  while IFS= read -r kc; do
    ORIGINAL_KEYCHAINS+=("$kc")
  done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')

  KC_PW="$(openssl rand -base64 24 | tr -d '\n')"
  P12_PW="$(openssl rand -base64 24 | tr -d '\n')"

  # Rebuild a throwaway p12 from cert.pem + key.pem with a fresh, one-off
  # password — the original p12's password was random, printed once at
  # scripts/release-cert.sh time, and lives only (unreadably) as a GitHub
  # secret. Not needed: same key -> same cert -> identical designated
  # requirement, regardless of what password wraps the p12 container.
  # -legacy matches release-cert.sh's own export (macOS's Security framework
  # cannot import OpenSSL 3's default PKCS#12 encryption).
  openssl pkcs12 -export -legacy \
    -out "$WORK_DIR/release.p12" \
    -inkey "$RELEASE_CERT_DIR/key.pem" -in "$RELEASE_CERT_DIR/cert.pem" \
    -name "$IDENTITY" -passout "pass:$P12_PW" >/dev/null 2>&1 \
    || die "openssl could not rebuild the release p12 from $RELEASE_CERT_DIR"

  security create-keychain -p "$KC_PW" "$KEYCHAIN"
  KEYCHAIN_CREATED=1
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KC_PW" "$KEYCHAIN"
  security import "$WORK_DIR/release.p12" -k "$KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign \
    || die "security import failed"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KEYCHAIN" >/dev/null \
    || die "security set-key-partition-list failed"
  # codesign resolves identities via the keychain SEARCH LIST, not just
  # whatever keychain a signing command happens to reference — the temp
  # keychain has to be in that list (verified empirically; a `--keychain`
  # flag on codesign alone is NOT sufficient). Prepended, not replacing, so
  # every other keychain (e.g. the login keychain, which is where
  # scripts/dev-cert.sh's "Clipnest Local Dev" identity lives) stays
  # reachable for the rest of this shell session.
  security list-keychains -d user -s "$KEYCHAIN" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}

  # This is a self-signed cert with no trust setting (deliberately — adding
  # one with `security add-trusted-cert` would write a trust entry that
  # OUTLIVES this temporary keychain, which is exactly the kind of
  # undocumented manual change this script must never leave behind). That
  # means `security find-identity -v ...` (the "-v" = valid/trusted check)
  # will always report 0 valid identities for it — that is EXPECTED, not a
  # failure, and is not what's checked below.
  IDENTITY_COUNT="$(security find-identity -p codesigning "$KEYCHAIN" | grep -cF "\"$IDENTITY\"" || true)"
  [ "$IDENTITY_COUNT" = "1" ] || die "expected exactly one codesigning identity named \"$IDENTITY\" in the temp keychain, found $IDENTITY_COUNT. List installed identities with: security find-identity -p codesigning \"$KEYCHAIN\""

  # The actual usability proof: test-sign a throwaway Mach-O binary. This is
  # what catches errSecInternalComponent / a bad partition list / a
  # keychain-search-list problem BEFORE the slow archive, not after.
  printf 'int main(void) { return 0; }\n' >"$WORK_DIR/identity-check.c"
  cc -o "$WORK_DIR/identity-check" "$WORK_DIR/identity-check.c" || die "cc failed to compile the throwaway identity-check binary — is Xcode / Command Line Tools installed?"
  if ! codesign --sign "$IDENTITY" --force "$WORK_DIR/identity-check" >"$WORK_DIR/identity-check.log" 2>&1; then
    cat "$WORK_DIR/identity-check.log" >&2
    die "signing identity \"$IDENTITY\" is not usable for codesign — checked now, before the slow build, not after. See the codesign error above."
  fi
  log "signing identity \"$IDENTITY\" is ready and verified usable (temporary keychain)"
  log "notarization: SKIPPED, deliberately — \"$IDENTITY\" is self-signed, not a Developer ID, so Apple's notary service cannot accept it. The signature alone is what matters: it pins the designated requirement to this stable certificate root, and curl-based installs (scripts/install.sh / update.sh) never set com.apple.quarantine, so Gatekeeper's notarization check never triggers for the supported install path."

  # -------------------------------------------------------------------- build --
  log "building (scripts/build.sh)"
  # Explicitly unset: DEVELOPMENT_TEAM would push build.sh onto its
  # `xcodebuild -exportArchive` (Developer ID export) path, which this
  # project doesn't use — every real release since v0.7.0 has gone through
  # the ad-hoc-export-then-scripts/sign.sh path below instead.
  ( unset DEVELOPMENT_TEAM; "$REPO_ROOT/scripts/build.sh" )
  [ -d "$APP_PATH" ] || die "build.sh reported success but $APP_PATH is missing"

  # Defensive re-assertion, not redundant: the keychain search list is
  # shared, global, per-user state (not scoped to this script's process
  # tree), and the archive build above just ran for several minutes.
  # Empirically confirmed while building this script: something else running
  # concurrently on the same machine during that window CAN silently reset
  # the search list, and codesign resolves identities via that list, not via
  # any --keychain flag alone — so re-apply it right before the signing step
  # that actually depends on it, instead of trusting the one-time setup from
  # before the slow build to have survived undisturbed.
  security list-keychains -d user -s "$KEYCHAIN" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
  IDENTITY_COUNT="$(security find-identity -p codesigning "$KEYCHAIN" | grep -cF "\"$IDENTITY\"" || true)"
  [ "$IDENTITY_COUNT" = "1" ] || die "signing identity \"$IDENTITY\" is no longer found in the temp keychain right before signing (found $IDENTITY_COUNT matches) — something reset the keychain search list during the build. Re-run."

  log "signing with \"$IDENTITY\" (scripts/sign.sh)"
  "$REPO_ROOT/scripts/sign.sh" "$IDENTITY"

  DR_OUTPUT="$(codesign -d -r- "$APP_PATH" 2>&1)"
  printf '%s\n' "$DR_OUTPUT" | grep -qF 'certificate root = H"' || die "designated requirement has no stable certificate root after signing — signing may have silently fallen back to ad-hoc. Full output:
$DR_OUTPUT"
  printf '%s\n' "$DR_OUTPUT" | grep -qF 'cdhash H"' && die "designated requirement pins a cdhash (per-build hash) instead of the stable certificate root — this would break every existing user's Accessibility grant on update. Full output:
$DR_OUTPUT"
  printf '%s\n' "$DR_OUTPUT" | grep -qF "identifier \"$BUNDLE_ID\"" || die "designated requirement's identifier does not match $BUNDLE_ID. Full output:
$DR_OUTPUT"
  log "designated requirement OK — stable certificate root, no cdhash:"
  printf '%s\n' "$DR_OUTPUT"

  log "packaging (scripts/package_dmg.sh)"
  "$REPO_ROOT/scripts/package_dmg.sh"
  [ -f "$BUILD_DIR/Clipnest.dmg" ] || die "package_dmg.sh reported success but $BUILD_DIR/Clipnest.dmg is missing"
  mv "$BUILD_DIR/Clipnest.dmg" "$DMG_OUT"

  # Exact format release.yml publishes: `shasum -a 256`-shaped, two spaces,
  # `<hash>  <filename>` — this is what scripts/install.sh / update.sh parse
  # with `grep -oE '[0-9a-fA-F]{64}'`, and what `shasum -a 256 -c` accepts
  # directly by hand.
  SHA256="$(shasum -a 256 "$DMG_OUT" | awk '{print $1}')"
  printf '%s  %s\n' "$SHA256" "$(basename "$DMG_OUT")" >"$CHECKSUM_OUT"
  log "checksum: $SHA256  $(basename "$DMG_OUT")"
fi

log "release artifact ready: $DMG_OUT"
ls -la "$DMG_OUT" "$CHECKSUM_OUT"

if [ "$DRY_RUN" = 1 ]; then
  log "dry run complete — nothing was uploaded or published. Nothing remote was touched."
  log "artifact:  $DMG_OUT"
  log "checksum:  $CHECKSUM_OUT  ($(cat "$CHECKSUM_OUT"))"
  exit 0
fi

# ------------------------------------------------------------ draft release --
SHA256="$(awk '{print $1}' "$CHECKSUM_OUT")"
COMMIT_SHA="$(git rev-parse HEAD)"

if [ "$RELEASE_EXISTS" = 1 ]; then
  log "reusing existing draft release v$VERSION"
else
  log "creating draft release v$VERSION (target $COMMIT_SHA)"
  gh release create "v$VERSION" --repo "$REPO_SLUG" --draft \
    --title "Clipnest v$VERSION" \
    --target "$COMMIT_SHA" \
    --generate-notes \
    --notes "**SHA-256:** \`$SHA256\`"
fi

log "uploading $(basename "$DMG_OUT") and $(basename "$CHECKSUM_OUT") to the draft"
gh release upload "v$VERSION" --repo "$REPO_SLUG" --clobber "$DMG_OUT" "$CHECKSUM_OUT"

# Confirm both assets are ACTUALLY on the draft before publishing — this is
# the entire point of draft-first (guarantee #2 in the header above).
ASSET_NAMES="$(gh release view "v$VERSION" --repo "$REPO_SLUG" --json assets -q '.assets[].name')"
printf '%s\n' "$ASSET_NAMES" | grep -qxF "$(basename "$DMG_OUT")" \
  || die "uploaded but $(basename "$DMG_OUT") is not listed on the draft — do NOT publish. Investigate: gh release view v$VERSION --repo $REPO_SLUG"
printf '%s\n' "$ASSET_NAMES" | grep -qxF "$(basename "$CHECKSUM_OUT")" \
  || die "uploaded but $(basename "$CHECKSUM_OUT") is not listed on the draft — do NOT publish (this is exactly the window that would make install.sh/update.sh fail closed on every install and update). Investigate: gh release view v$VERSION --repo $REPO_SLUG"
log "confirmed both assets are present on the draft:"
printf '%s\n' "$ASSET_NAMES"

if [ "$KEEP_DRAFT" = 1 ]; then
  log "--keep-draft: v$VERSION is staged but NOT published"
  log "inspect:  gh release view v$VERSION --repo $REPO_SLUG --web"
  log "publish:  gh release edit v$VERSION --repo $REPO_SLUG --draft=false --latest"
  exit 0
fi

log "publishing v$VERSION"
gh release edit "v$VERSION" --repo "$REPO_SLUG" --draft=false --latest

log "released v$VERSION"
log "https://github.com/$REPO_SLUG/releases/tag/v$VERSION"
