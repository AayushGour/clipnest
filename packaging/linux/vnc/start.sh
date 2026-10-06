#!/usr/bin/env bash
# Brings up Xvfb + a window manager + VNC, then launches Clipnest.
set -u

echo "[vnc] starting Xvfb on :1"
Xvfb :1 -screen 0 1440x900x24 -nolisten tcp &
for i in $(seq 1 50); do xdpyinfo -display :1 >/dev/null 2>&1 && break; sleep 0.1; done

echo "[vnc] starting session dbus"
eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS

echo "[vnc] starting openbox"
openbox &

echo "[vnc] starting x11vnc + noVNC on :6080"
x11vnc -display :1 -forever -shared -nopw -quiet -bg >/dev/null 2>&1
websockify --web=/usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &

# A terminal, so the tester can drive clipnest-ctl and inspect logs by hand.
xterm -geometry 100x28+20+520 -title "Clipnest test shell" &

echo "[vnc] launching clipnest"
clipnest 2>&1 | tee /tmp/clipnest.log &

cat <<'BANNER'

  Clipnest is running under Xvfb.  Open:  http://localhost:6080/vnc.html

  Try:
    clipnest-ctl toggle-picker     # show/hide the picker
    echo hello | xclip -selection clipboard
    xclip -selection clipboard -o
    tail -f /tmp/clipnest.log

  NOT testable here: the GNOME Shell extension (needs systemd/logind),
  so cursor placement and above-fullscreen are out of scope.

BANNER
tail -f /dev/null
