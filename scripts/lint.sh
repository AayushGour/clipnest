#!/usr/bin/env bash
#
# scripts/lint.sh — the ONE reproducible swift-format lint gate (T-LINT2).
#
# Why this exists: `.github/workflows/ci.yml` lints inside `swift:6.0-jammy`,
# whose bundled swift-format is built from swift-format's `main` branch
# (`swift format --version` => "main"), NOT a tagged release. A developer's
# own machine runs whatever Swift toolchain they installed (e.g. Apple's
# Swift 6.3.x on macOS, `swift format --version` => "6.3.0") — a DIFFERENT
# binary that can and does disagree with CI on real code: verified, the two
# wrap a multi-line `@escaping` closure-type parameter differently, and a
# file-scoped `// swift-format-ignore-file: <Rule>` directive is honoured by
# Apple's build but silently ignored by swift-format `main`. Two reviewers
# hit exactly this and reached opposite verdicts on the same line of
# SettingsWindow.swift. See .claude/task-board.md T-LINT2 and
# .claude/logs/reviewer.md's 2026-09-08 entry for the full paper trail.
#
# The fix: don't trust "whatever swift-format is on PATH." Run the LITERAL
# SAME BINARY ci.yml uses, and refuse to silently certify "lint clean"
# against anything else. Concretely, this script:
#   1. Checks whatever `swift format --version` resolves to right now.
#   2. If it matches $EXPECTED_SWIFT_FORMAT_VERSION (true when already
#      running inside the pinned image — i.e. this is exactly what CI's own
#      job does — or when a host toolchain happens to be byte-identical),
#      it runs the real lint command natively. Zero extra overhead.
#   3. If it does NOT match (the normal case on a developer's own machine,
#      e.g. this Mac's Apple swift-format reporting "6.3.0"), it re-executes
#      itself inside $PINNED_LINT_IMAGE via `docker run` — so the verdict
#      always comes from the exact binary CI trusts, never an approximation.
#   4. If docker isn't available AND the version doesn't match: FAILS LOUD.
#      A silent mismatch is the entire defect this script exists to remove —
#      never fall back to trusting an unpinned local swift-format.
#
# Usage:
#   scripts/lint.sh                              # lints Sources Tests (ci.yml's set)
#   scripts/lint.sh Sources Tests                 # explicit, same thing
#   LINT_IMAGE=swift:6.0-noble scripts/lint.sh    # cross-check ci.yml's other
#                                                   # matrix leg
#
# Rejected alternatives (full writeup: .claude/logs/devops.md T-LINT2):
#   - Pin an exact swift-format via a new SwiftPM dependency (`swift run`):
#     would add a SECOND third-party dependency against coding-standards.md's
#     "exactly one dependency" policy without being asked to, AND still
#     wouldn't match CI — swift:6.0-jammy bundles a `main`-branch build, not
#     a tagged release, so pinning a release tag introduces a THIRD
#     disagreeing version instead of resolving the two that exist today.
#   - A root `.swift-format` rules config: can't help here. The disputed
#     behavior (how a multi-line `@escaping` closure-type parameter wraps)
#     is the pretty-printer's internal line-wrap algorithm, not a toggleable
#     rule — `swift format dump-configuration` has no such knob. Verified by
#     testing: an empty/default root `.swift-format` changes zero verdicts.
#   - Document a required toolchain version, by hand, with no enforcement:
#     doesn't work even in principle here, because "main" is a moving branch
#     build baked into a specific Docker image tag, not a swift.org-installable
#     release — there is no toolchain a developer can "just go install" that
#     reproduces it. The image itself is the only reproducible artifact.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Must match .github/workflows/ci.yml's `container: swift:6.0-${{ matrix.series }}`
# (matrix: jammy, noble). jammy is the canonical image this script certifies
# against by default; override with LINT_IMAGE=swift:6.0-noble to spot-check
# the matrix's other leg.
PINNED_LINT_IMAGE="${LINT_IMAGE:-swift:6.0-jammy}"

# What that pinned image's bundled swift-format reports today — verified
# directly: `docker run --rm swift:6.0-jammy swift format --version` => main.
# It is a branch build, not a semver release. If this ever legitimately
# changes (e.g. Docker Hub rebuilds the tag against a newer swift-format
# main), update this constant deliberately, after confirming the new lint
# verdicts are intended — never silence this check instead.
EXPECTED_SWIFT_FORMAT_VERSION="main"

log() { printf '[lint.sh] %s\n' "$*"; }
fail() {
	printf '[lint.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

LINT_PATHS=("$@")
if [ "${#LINT_PATHS[@]}" -eq 0 ]; then
	LINT_PATHS=(Sources Tests)
fi

command -v swift >/dev/null 2>&1 || fail "swift not found on PATH — install a Swift toolchain first"

actual_version="$(swift format --version 2>/dev/null || true)"
[ -n "$actual_version" ] || fail "'swift format --version' produced no output — is a Swift toolchain installed?"

if [ "$actual_version" = "$EXPECTED_SWIFT_FORMAT_VERSION" ]; then
	log "swift-format version '$actual_version' matches the pinned CI toolchain ($PINNED_LINT_IMAGE) — linting natively."
	exec swift format lint --recursive --strict "${LINT_PATHS[@]}"
fi

# Version mismatch: this is the exact defect T-LINT2 exists to catch loudly,
# instead of two people quietly trusting two different binaries.
log "swift-format version mismatch: got '$actual_version', CI's pinned $PINNED_LINT_IMAGE reports '$EXPECTED_SWIFT_FORMAT_VERSION'."
log "Refusing to certify lint against a different binary than CI trusts — re-running inside $PINNED_LINT_IMAGE."

if [ "${CLIPNEST_LINT_REEXEC:-0}" = "1" ]; then
	fail "already re-executed once inside a container and STILL got '$actual_version' (expected '$EXPECTED_SWIFT_FORMAT_VERSION'). $PINNED_LINT_IMAGE's bundled swift-format has drifted from what this script expects — update EXPECTED_SWIFT_FORMAT_VERSION in scripts/lint.sh only after confirming the new lint verdicts are intended. Do not silence this check."
fi

command -v docker >/dev/null 2>&1 || fail "docker not found — required to run the reproducible lint gate ($PINNED_LINT_IMAGE) since the local toolchain ('$actual_version') doesn't match CI ('$EXPECTED_SWIFT_FORMAT_VERSION'). Install Docker Desktop, or set LINT_IMAGE to a toolchain you've separately verified agrees with CI. Do not just trust the local result."
docker info >/dev/null 2>&1 || fail "docker is installed but its daemon is not running — start it, then re-run scripts/lint.sh"

log "Pulling $PINNED_LINT_IMAGE (no-op if already current)..."
docker pull --quiet "$PINNED_LINT_IMAGE" >/dev/null

exec docker run --rm \
	-e CLIPNEST_LINT_REEXEC=1 \
	-e LINT_IMAGE="$PINNED_LINT_IMAGE" \
	-v "$REPO_ROOT":/work \
	-w /work \
	"$PINNED_LINT_IMAGE" \
	scripts/lint.sh "${LINT_PATHS[@]}"
