#!/usr/bin/env bash
# fetch.sh — (re)populate packaging/linux/vendor/ppocr-models/ from RapidOCR's
# official ModelScope-hosted ONNX conversion of PP-OCRv5.
#
# WHEN TO RUN THIS: only when bumping RAPIDOCR_RELEASE_TAG below, or to verify
# the committed vendor tree still matches upstream. This is NEVER invoked by
# debian/rules or any CI build step — Launchpad's PPA build farm has no
# network access during a build, so everything under this directory must
# already be committed to the source tree before `dpkg-buildpackage`/`dput`
# ever runs (this package builds as `3.0 (native)` — see debian/source/format
# — so there is no separate orig-tarball step to hook this into; it is a
# plain pre-commit maintenance script, mirroring
# packaging/linux/vendor/onnxruntime/fetch.sh's own precedent exactly). Run
# this locally (it needs network), inspect the diff, then `git add` the
# result — see SOURCE.md's "Why these four files, and why vendored at all"
# section for why the binaries are committed rather than fetched in CI.
#
# Safe to re-run: downloads to a temp dir, verifies EVERY checksum BEFORE
# touching anything under this directory.
set -euo pipefail

# Single source of truth for the pinned RapidOCR release tag + each file's
# real, upstream-published SHA-256 (verified once at vendoring time, cross-
# checked against RapidOCR's own default_models.yaml at this exact tag — see
# SOURCE.md's Provenance section; update the tag and ALL FOUR checksums
# together when bumping).
RAPIDOCR_RELEASE_TAG="v3.9.2"
BASE_URL="https://modelscope.cn/models/RapidAI/RapidOCR/resolve/${RAPIDOCR_RELEASE_TAG}"

declare -A FILE_TO_URL_PATH=(
  [det.onnx]="onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx"
  [rec.onnx]="onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx"
  [cls.onnx]="onnx/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx"
  [dict.txt]="paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt"
)
declare -A FILE_SHA256=(
  [det.onnx]="4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae"
  [rec.onnx]="5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5"
  [cls.onnx]="54379ae5174d026780215fc748a7f31910dee36818e63d49e17dc598ecc82df7"
  [dict.txt]="d1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b"
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in "${!FILE_TO_URL_PATH[@]}"; do
  url="${BASE_URL}/${FILE_TO_URL_PATH[$f]}"
  echo "fetching ${url}"
  curl -fsSL -o "$WORK/$f" "$url"

  expected="${FILE_SHA256[$f]}"
  actual="$(shasum -a 256 "$WORK/$f" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "SECURITY: checksum mismatch for $f" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "Refusing to vendor an unverified download. If this is a deliberate" >&2
    echo "version bump, update FILE_SHA256 above from a trusted source" >&2
    echo "(RapidOCR's own default_models.yaml at the new tag / a second" >&2
    echo "independent download) first — never silence this check." >&2
    exit 1
  fi
done

for f in "${!FILE_TO_URL_PATH[@]}"; do
  cp "$WORK/$f" "$HERE/$f"
  chmod 644 "$HERE/$f"
done

echo "$RAPIDOCR_RELEASE_TAG" > "$HERE/VERSION"
echo "Done. Review with 'git status'/'git diff --stat' before 'git add'."
