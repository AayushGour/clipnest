#!/usr/bin/env bash
# Fast, no-gjs-needed regression test for build.sh's ESM export-generation
# step (T-EXT-ESM-BROKEN1: the esm variant had zero exports and could not
# load on any Shell 45+ -- "SyntaxError: ambiguous indirect export").
#
# Complements:
#   - test/*.test.js (real-gjs unit tests for src/core/'s own logic)
#   - packaging/linux/gnome-shell-test/run-noble-esm-test.sh (the full,
#     Docker + real-GNOME-Shell-46 end-to-end regression gate)
# with something that runs anywhere plain bash + grep/sed/diff do, in under
# a second, with no gjs and no Docker -- so this specific defect class (a
# generated file silently missing an export) fails fast, every time.
#
# Run: extension/test/build.esm-exports.test.sh
# Exits 0 with "ALL PASS" on success, non-zero with "FAILURES: N" otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(cd "$HERE/.." && pwd)"

pass=0
fail=0
ok() {
  if [[ "$1" -eq 0 ]]; then pass=$((pass + 1)); echo "PASS $2";
  else fail=$((fail + 1)); echo "FAIL $2"; fi
}

"$EXT/build.sh" >/dev/null

# 1. legacy's copies must stay byte-identical to src/core/*.js -- the whole
#    point of "one source tree, no fork" (see build.sh's own header comment).
for f in "$EXT"/src/core/*.js; do
  b="$(basename "$f")"
  diff -q "$f" "$EXT/dist/legacy/core/$b" >/dev/null 2>&1
  ok "$?" "dist/legacy/core/$b is byte-identical to src/core/$b"
done

# 2. src/core/*.js itself must never gain an export -- the fix is additive,
#    applied only to the copy placed under dist/esm, never to the single
#    source of truth.
for f in "$EXT"/src/core/*.js; do
  b="$(basename "$f")"
  if grep -q '^export ' "$f"; then
    ok 1 "src/core/$b has no top-level export (still legacy-style var globals)"
  else
    ok 0 "src/core/$b has no top-level export (still legacy-style var globals)"
  fi
done

# 3. every esm copy gets a real named export for every top-level `var NAME =`
#    src/core/*.js declares -- this is the actual defect: zero exports,
#    anywhere, before this fix.
for f in "$EXT"/src/core/*.js; do
  b="$(basename "$f")"
  esm_f="$EXT/dist/esm/core/$b"
  names="$(grep -oE '^var [A-Za-z_][A-Za-z0-9_]*' "$f" | sed 's/^var //')"
  for name in $names; do
    if grep -qE "export \{[^}]*\b$name\b[^}]*\};" "$esm_f"; then
      ok 0 "dist/esm/core/$b exports $name"
    else
      ok 1 "dist/esm/core/$b exports $name"
    fi
  done
done

# 4. entry-esm.js's own named imports FROM ./core/*.js (excluding the
#    Extension base class and ./imports.js's `deps`, neither of which core/
#    is expected to export) must each resolve to a real export somewhere in
#    dist/esm/core/*.js -- reproduces the exact regression ("SyntaxError:
#    ambiguous indirect export: ClipboardWatcher") this fix targets: an
#    import with nothing backing it.
imported_names="$(grep -E "^import \{ *[A-Za-z_]+ *\} from '\./core/" "$EXT/src/entry-esm.js" \
  | sed -E "s/^import \{ *([A-Za-z_]+) *\}.*/\1/")"
for name in $imported_names; do
  if grep -qrE "export \{[^}]*\b$name\b[^}]*\};" "$EXT/dist/esm/core/"*.js; then
    ok 0 "entry-esm.js's import of $name resolves to a real dist/esm export"
  else
    ok 1 "entry-esm.js's import of $name resolves to a real dist/esm export"
  fi
done

echo ""
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "FAILURES: $fail"
  exit 1
fi
echo "ALL PASS"
