#!/usr/bin/env bash
# fetch.sh — (re)populate packaging/linux/vendor/onnxruntime/{amd64,arm64}/ from
# upstream ONNX Runtime release tarballs.
#
# WHEN TO RUN THIS: only when bumping ONNXRUNTIME_VERSION below, or to verify the
# committed vendor tree still matches upstream. This is NEVER invoked by
# debian/rules or any CI build step — Launchpad's PPA build farm has no network
# access during a build, so everything under this directory must already be
# committed to the source tree before `dpkg-buildpackage`/`dput` ever runs
# (this package builds as `3.0 (native)` — see debian/source/format — so
# there is no separate orig-tarball step to hook this into; it is a plain
# pre-commit maintenance script). Run this locally (it needs network),
# inspect the diff, then `git add` the result —
# see SOURCE.md's "Repo-size note" for why the binaries are committed at all
# rather than fetched in CI.
#
# Safe to re-run: downloads to a temp dir, verifies checksums BEFORE touching
# anything under this directory, and only copies out the specific files this
# project actually uses (see SOURCE.md's "What's here, and why").
set -euo pipefail

# Single source of truth for the pinned version + its real, upstream-published
# SHA-256 of each full release tarball (verified once at vendoring time — see
# SOURCE.md's Provenance section; update both the version and BOTH checksums
# together when bumping).
ONNXRUNTIME_VERSION="1.28.1"
declare -A ORT_ARCH_TO_DEB_ARCH=([x64]="amd64" [aarch64]="arm64")
declare -A TARBALL_SHA256=(
  [x64]="2529aef968d0ad0603365054bc46ebefa7f0fe3bc12f28c5f729c99ddffe2a81"
  [aarch64]="53bab9a5c6ae198b7be75663b780c64caa388d30257fac458c71fbff0a82e98e"
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for ort_arch in "${!ORT_ARCH_TO_DEB_ARCH[@]}"; do
  deb_arch="${ORT_ARCH_TO_DEB_ARCH[$ort_arch]}"
  tarball="onnxruntime-linux-${ort_arch}-${ONNXRUNTIME_VERSION}.tgz"
  url="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/${tarball}"

  echo "== ${deb_arch} (upstream ${ort_arch}) =="
  echo "fetching ${url}"
  curl -fsSL -o "$WORK/$tarball" "$url"

  expected="${TARBALL_SHA256[$ort_arch]}"
  actual="$(shasum -a 256 "$WORK/$tarball" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "SECURITY: checksum mismatch for $tarball" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "Refusing to vendor an unverified download. If this is a deliberate" >&2
    echo "version bump, update TARBALL_SHA256 above from a trusted source" >&2
    echo "(upstream's own release notes / a second independent download)" >&2
    echo "first — never silence this check." >&2
    exit 1
  fi

  extract_dir="$WORK/onnxruntime-linux-${ort_arch}-${ONNXRUNTIME_VERSION}"
  tar xzf "$WORK/$tarball" -C "$WORK" \
    "onnxruntime-linux-${ort_arch}-${ONNXRUNTIME_VERSION}/include" \
    "onnxruntime-linux-${ort_arch}-${ONNXRUNTIME_VERSION}/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}" \
    "onnxruntime-linux-${ort_arch}-${ONNXRUNTIME_VERSION}/lib/libonnxruntime_providers_shared.so" \
    "onnxruntime-linux-${ort_arch}-${ONNXRUNTIME_VERSION}/LICENSE"

  dest="$HERE/$deb_arch"
  rm -rf "$dest"
  mkdir -p "$dest/lib"
  cp -R "$extract_dir/include" "$dest/include"
  cp "$extract_dir/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}" \
    "$dest/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}"
  cp "$extract_dir/lib/libonnxruntime_providers_shared.so" \
    "$dest/lib/libonnxruntime_providers_shared.so"
  ln -sf "libonnxruntime.so.${ONNXRUNTIME_VERSION}" "$dest/lib/libonnxruntime.so.1"
  cp "$extract_dir/LICENSE" "$dest/LICENSE"
  chmod 644 "$dest/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}" \
    "$dest/lib/libonnxruntime_providers_shared.so"

  echo "vendored: $dest (lib $(du -h "$dest/lib/libonnxruntime.so.${ONNXRUNTIME_VERSION}" | cut -f1))"
done

echo "$ONNXRUNTIME_VERSION" > "$HERE/VERSION"
echo "Done. Review with 'git status'/'git diff --stat' before 'git add'."
