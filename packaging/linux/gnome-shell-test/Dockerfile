# Real GNOME Shell 42 (Ubuntu 22.04 jammy, matches the existing Linux
# packaging pipeline) under systemd-as-PID1 + Xvfb, to actually exercise the
# extension against a real Mutter instead of a fake. See devops investigation
# notes for how this differs from packaging/linux/vnc/Dockerfile (which uses
# a bare `docker run`, no systemd/logind, and explicitly cannot load the
# shell extension).
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq \
      systemd systemd-sysv dbus dbus-x11 \
      gnome-shell gnome-session-bin gnome-session-common mutter \
      gsettings-desktop-schemas at-spi2-core \
      xvfb x11-xserver-utils x11-utils xterm \
      libglib2.0-bin libsqlite3-0 libx11-6 libxfixes3 libxtst6 \
      xclip xdotool wmctrl curl \
    && rm -rf /var/lib/apt/lists/*
COPY *.deb /tmp/
RUN apt-get update -qq \
    && apt-get install -y -qq /tmp/clipnest_*.deb 2>&1 | tail -30 \
    && rm -rf /var/lib/apt/lists/* /tmp/*.deb
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
