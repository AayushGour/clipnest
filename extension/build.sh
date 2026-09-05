#!/usr/bin/env bash
# Emits two installable variants from one source tree.
#
# The ESM break at Shell 45 is a PARSE-level incompatibility, so a single file
# cannot serve both. Rather than maintain two branches (which drift), core/ is
# written with zero imports and receives its GI namespaces by injection; only
# the thin shim and entry point differ per variant.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/dist"
rm -rf "$OUT"

for variant in legacy esm; do
  d="$OUT/$variant"
  mkdir -p "$d/core"
  cp "$HERE"/src/core/*.js "$d/core/"
  cp "$HERE/src/shims/$variant/imports.js" "$d/imports.js"
  cp "$HERE/src/entry-$variant.js" "$d/extension.js"
  cp "$HERE/src/metadata-$variant.json" "$d/metadata.json"
  cp -r "$HERE/schemas" "$d/schemas" 2>/dev/null || true
done
echo "built: $OUT/legacy (Shell 42-44), $OUT/esm (Shell 45-50)"
