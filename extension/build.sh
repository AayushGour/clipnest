#!/usr/bin/env bash
# Emits two installable variants from one source tree.
#
# The ESM break at Shell 45 is a PARSE-level incompatibility, so a single file
# cannot serve both. Rather than maintain two branches (which drift), core/ is
# written with zero imports and receives its GI namespaces by injection; only
# the thin shim and entry point differ per variant.
#
# core/*.js is also written with zero EXPORTS (legacy style: `var X = class
# X {...}`), because GJS's pre-45 `imports.gi` world resolves those as plain
# global `var`s via `Me.imports.core.x` -- no export statement needed, and
# adding one there is harmless but pointless (see entry-legacy.js). Shell 45+
# is real ESM, though: `entry-esm.js` does `import { X } from './core/x.js'`,
# which requires a genuine named export, and legacy `var` declarations don't
# produce one (T-EXT-ESM-BROKEN1 -- `gnome-extensions enable` errored with
# "ambiguous indirect export" because nothing in core/ exported anything).
# Fix, applied ONLY to the copy placed under dist/esm (dist/legacy and
# src/core/*.js itself are never touched, so src/core/*.js stays the single
# source of truth core/'s own header comment promises): mechanically scan
# each top-level `var NAME = ...` in the copied file and append a trailing
# `export { NAME, ... };` line. This is additive-only -- no existing line is
# edited -- so it doesn't fork the tree, it just completes the ESM half of
# the same dependency-injection story the header above already describes for
# imports.
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

  if [[ "$variant" == esm ]]; then
    for f in "$d"/core/*.js; do
      names="$(grep -oE '^var [A-Za-z_][A-Za-z0-9_]*' "$f" | sed 's/^var //')"
      if [[ -n "$names" ]]; then
        export_list="$(echo "$names" | paste -sd ',' - | sed 's/,/, /g')"
        printf '\n// Appended by build.sh for the esm variant only -- see this file'"'"'s\n// header comment. src/core/%s is unmodified; legacy'"'"'s var globals are\n// untouched.\nexport { %s };\n' "$(basename "$f")" "$export_list" >> "$f"
      fi
    done
  fi
done
echo "built: $OUT/legacy (Shell 42-44), $OUT/esm (Shell 45-50)"
