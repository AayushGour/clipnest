#!/bin/bash
# Boots Xvfb + a real gnome-shell (X11 backend) as the payload of a
# `systemd-run -p PAMName=login` transient unit -- see README.md in this
# directory for why the systemd-run invocation (not this script) is what
# actually matters (a real, correctly-*typed* logind session).
set -x
export HOME=/home/gtester
Xvfb :99 -screen 0 1440x900x24 -nolisten tcp &
for i in $(seq 1 50); do DISPLAY=:99 xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
export DISPLAY=:99
exec gnome-shell --x11 --display=:99
