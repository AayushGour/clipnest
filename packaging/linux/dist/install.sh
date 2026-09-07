#!/usr/bin/env bash
# Installs Clipnest from the .deb files shipped alongside this script.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root - it uses sudo only where needed." >&2
  exit 1
fi

arch_pkg="$(ls clipnest_*.deb 2>/dev/null | head -1)"
if [ -z "$arch_pkg" ]; then
  echo "No clipnest .deb found next to this script." >&2
  exit 1
fi

deb_arch="$(dpkg-deb -f "$arch_pkg" Architecture)"
host_arch="$(dpkg --print-architecture)"
if [ "$deb_arch" != "$host_arch" ]; then
  echo "Architecture mismatch: these packages are $deb_arch, this machine is $host_arch." >&2
  echo "Download the $host_arch tarball instead." >&2
  exit 1
fi

echo "Installing Clipnest ($deb_arch)..."
# apt resolves the runtime dependencies dpkg-shlibdeps derived; ./ prefix is
# required or apt treats the argument as a package name from the archive.
sudo apt-get update -qq
sudo apt-get install -y ./clipnest_*.deb ./clipnest-ocr_*.deb ./clipnest-ocr-data_*.deb

cat <<'DONE'

Clipnest is installed.

  Start it:            clipnest &
  Open the picker:     clipnest-ctl toggle-picker
  Settings:            clipnest-ctl open-settings

Two things worth knowing:

1. Auto-paste needs one extra permission. Open Settings -> Permissions and
   grant it there. It adds you to the "clipnest-input" group, which allows
   creating a virtual keyboard device and nothing else - notably NOT the
   "input" group, which would let any program read your keystrokes.
   You must log out and back in for group membership to take effect.
   Without it, Clipnest still copies to your clipboard; you paste manually.

2. The GNOME Shell extension is optional. Clipnest works without it. With it,
   the picker can open at your cursor and appear above fullscreen windows:
     gnome-extensions install --force \
       /usr/share/clipnest/gnome-shell-extension/<variant>
   Pick "esm" for GNOME 45+, "legacy" for GNOME 42-44. Then log out and in.

DONE
