#!/bin/sh
# Fixture test for clipnest-install-update. Run as root in a throwaway Debian/
# Ubuntu container (it really runs apt-get on the good case):
#   docker run --rm -v "$PWD":/src -w /src ubuntu:24.04 sh packaging/linux/tests/test-install-update.sh
set -u
HELPER=/src/packaging/linux/scripts/clipnest-install-update
fail=0
check() { # name expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want rc=$2 got rc=$3)"; fail=1; fi
}
W=$(mktemp -d)
mk() { # name pkg [version]
  d="$W/$1"; mkdir -p "$d/DEBIAN"
  printf 'Package: %s\nVersion: '"${3:-9.9.9}"'\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' "$2" >"$d/DEBIAN/control"
  dpkg-deb --build "$d" "$W/$1.deb" >/dev/null 2>&1
}
mk good clipnest; mk other notclipnest
GOOD=$(sha256sum "$W/good.deb" | cut -d' ' -f1)

sh "$HELPER" "$GOOD" <"$W/good.deb" >/dev/null 2>&1; check "good file installs" 0 $?
dpkg -s clipnest >/dev/null 2>&1; check "clipnest is installed" 0 $?
dpkg -r clipnest >/dev/null 2>&1

cp "$W/good.deb" "$W/tampered.deb"; printf 'x' >>"$W/tampered.deb"
sh "$HELPER" "$GOOD" <"$W/tampered.deb" >/dev/null 2>&1; check "tampered file refused" 1 $?
dpkg -s clipnest >/dev/null 2>&1; check "tampered: nothing installed" 1 $?

for bad in "" "ABC" "$(echo "$GOOD" | tr a-f A-F)" "${GOOD}0" "; touch $W/pwned" "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"; do
  sh "$HELPER" "$bad" <"$W/good.deb" >/dev/null 2>&1; check "bad digest arg '$bad'" 1 $?
done
if [ -e "$W/pwned" ]; then rc=1; else rc=0; fi; check "no injection" 0 "$rc"
sh "$HELPER" <"$W/good.deb" >/dev/null 2>&1; check "no args refused" 1 $?
sh "$HELPER" "$GOOD" extra <"$W/good.deb" >/dev/null 2>&1; check "extra args refused" 1 $?

head -c 209715201 /dev/zero >"$W/big.deb"
BIGSUM=$(sha256sum "$W/big.deb" | cut -d' ' -f1)
sh "$HELPER" "$BIGSUM" <"$W/big.deb" >/dev/null 2>&1; check "oversize stdin refused" 1 $?
dpkg -s clipnest >/dev/null 2>&1; check "oversize: nothing installed" 1 $?
OTHER=$(sha256sum "$W/other.deb" | cut -d' ' -f1)
sh "$HELPER" "$OTHER" <"$W/other.deb" >/dev/null 2>&1; check "wrong package name refused" 1 $?

# Anti-downgrade: installed 9.9.9; older and same version must be refused (rc 3).
mk older clipnest 9.9.8; mk newer clipnest 9.9.10; mk epoch clipnest 1:0.1
OLDER=$(sha256sum "$W/older.deb" | cut -d' ' -f1)
NEWER=$(sha256sum "$W/newer.deb" | cut -d' ' -f1)
EPOCH=$(sha256sum "$W/epoch.deb" | cut -d' ' -f1)
sh "$HELPER" "$GOOD" <"$W/good.deb" >/dev/null 2>&1; check "reinstall baseline 9.9.9 (not installed)" 0 $?
sh "$HELPER" "$OLDER" <"$W/older.deb" >/dev/null 2>"$W/err"; check "downgrade 9.9.8 refused (rc 3)" 3 $?
grep -q "not newer" "$W/err"; check "downgrade message on stderr" 0 $?
dpkg-query -W -f='${Version}' clipnest | grep -qx 9.9.9; check "downgrade: version unchanged" 0 $?
sh "$HELPER" "$GOOD" <"$W/good.deb" >/dev/null 2>&1; check "same version refused (rc 3)" 3 $?
sh "$HELPER" "$NEWER" <"$W/newer.deb" >/dev/null 2>&1; check "upgrade 9.9.10 installs" 0 $?
sh "$HELPER" "$GOOD" <"$W/good.deb" >/dev/null 2>&1; check "downgrade from 9.9.10 refused (rc 3)" 3 $?
sh "$HELPER" "$EPOCH" <"$W/epoch.deb" >/dev/null 2>&1; check "epoch upgrade 1:0.1 installs" 0 $?
dpkg -r clipnest >/dev/null 2>&1
leftover=$(find /var/tmp -maxdepth 1 -name 'clipnest-update.*' | wc -l)
if [ "$leftover" -eq 0 ]; then rc=0; else rc=1; fi; check "workdir cleaned up" 0 "$rc"
exit $fail
