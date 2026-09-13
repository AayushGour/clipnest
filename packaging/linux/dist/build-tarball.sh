#!/usr/bin/env bash
#
# Assembles a clipnest-<version>-linux-<arch>.tar.gz release tarball from
# already-built .deb files, this directory's install.sh, and this
# directory's README.md.
#
# ONE recipe, used by both a local/manual rebuild and
# .github/workflows/release-linux.yml's build-tarball job -- so the
# checked-in-history tarballs and the CI-produced ones can never drift into
# two different layouts. If this script changes, both paths pick it up
# automatically; there is nothing else to keep in sync.
#
# Usage:
#   build-tarball.sh <version> <arch> <deb-dir> <output-dir>
#
#   <version>     e.g. 0.9.2
#   <arch>        amd64 | arm64 -- the Debian arch name, matching each
#                 .deb's own Architecture field and dpkg --print-architecture
#                 on the target machine (this is what install.sh compares
#                 against at install time).
#   <deb-dir>     Directory containing the three built .debs, unsuffixed
#                 (no "-jammy"/"-noble" series suffix -- this is the single
#                 generic build the standalone tarball ships, distinct from
#                 release-linux.yml's per-series apt/PPA .debs):
#                   clipnest_<version>_<arch>.deb
#                   clipnest-ocr_<version>_<arch>.deb
#                   clipnest-ocr-data_<version>_all.deb
#   <output-dir>  Directory to write clipnest-<version>-linux-<arch>.tar.gz
#                 into (created if missing).
set -euo pipefail

version="${1:?usage: build-tarball.sh <version> <arch> <deb-dir> <output-dir>}"
arch="${2:?usage: build-tarball.sh <version> <arch> <deb-dir> <output-dir>}"
deb_dir="${3:?usage: build-tarball.sh <version> <arch> <deb-dir> <output-dir>}"
out_dir="${4:?usage: build-tarball.sh <version> <arch> <deb-dir> <output-dir>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage_name="clipnest-${version}-linux-${arch}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$stage_name"
mkdir -p "$stage"

for deb in \
  "clipnest_${version}_${arch}.deb" \
  "clipnest-ocr_${version}_${arch}.deb" \
  "clipnest-ocr-data_${version}_all.deb"
do
  if [ ! -f "$deb_dir/$deb" ]; then
    echo "build-tarball.sh: missing $deb_dir/$deb" >&2
    exit 1
  fi
  cp "$deb_dir/$deb" "$stage/"
done

cp "$here/install.sh" "$stage/install.sh"
chmod +x "$stage/install.sh"
cp "$here/README.md" "$stage/README.md"

# shasum -a 256 is available on both macOS (local rebuilds) and Ubuntu
# runners (coreutils' sha256sum is a symlink target sha256sum, but shasum
# ships too via the perl-based tool on GitHub's ubuntu-* images) -- pin to
# shasum so the exact same command produces the exact same line format in
# both places.
( cd "$stage" && shasum -a 256 -- * > SHA256SUMS )

mkdir -p "$out_dir"
tarball="$out_dir/${stage_name}.tar.gz"

if [ "$(uname -s)" = "Darwin" ]; then
  # macOS's bsdtar (libarchive) otherwise embeds
  # LIBARCHIVE.xattr.com.apple.provenance extended-attribute headers, which
  # print seven warning lines on every Linux extraction. GNU tar (CI/Linux)
  # has neither the quirk nor these flags, so it takes the plain branch below.
  ( cd "$work" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$tarball" "$stage_name" )
else
  ( cd "$work" && tar -czf "$tarball" "$stage_name" )
fi

echo "wrote $tarball"
