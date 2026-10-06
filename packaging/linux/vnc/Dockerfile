# Runnable Clipnest-on-Ubuntu test environment, reachable over VNC in a browser.
#
# What this DOES exercise, for real:
#   - the GTK4 picker actually rendering
#   - X11 clipboard capture via XFixes (the primary backend on every session)
#   - XTEST synthetic paste (the X11 path)
#   - SQLite persistence, settings, snippets
#
# What it CANNOT exercise: the GNOME Shell extension. GNOME Shell needs
# systemd/logind and a real seat, which a container does not have. So
# cursor-anchored placement, above-fullscreen, and extension-mediated paste are
# out of scope here by construction -- see decisions D62 and the port plan's
# parity table.

# ---------- stage 1: build the .deb ----------
FROM swift:6.0-jammy AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      build-essential debhelper dpkg-dev fakeroot \
      libsqlite3-dev libx11-dev libxfixes-dev libxtst-dev libgtk-4-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . /src
# Native source format tars the whole tree; keep the build dir clean of host junk.
RUN rm -rf .build ClipnestApp/DerivedData build release-cert
# T-OCR9/T-OCR10 (real PP-OCRv5 weights now vendored, see
# packaging/linux/vendor/ppocr-models/SOURCE.md): the real model files are
# already committed to the source tree and flow through `COPY . /src` above
# like any other tracked file -- no zero-byte stand-ins needed (or wanted)
# anymore. `debian/rules` builds a genuinely working `clipnest-ocr-data`
# from them, so this image now exercises real, on-device OCR.
# NO pipe here: `cmd | tail` returns tail's exit status, which masked a
# real build failure and produced an empty stage.
RUN set -o pipefail; dpkg-buildpackage -us -uc -b -d 2>&1 | tail -40
RUN mkdir -p /out && cp /*.deb /out/ 2>/dev/null || cp ../*.deb /out/

# ---------- stage 2: X11 + VNC runtime ----------
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive DISPLAY=:1
RUN apt-get update -qq && apt-get install -y -qq \
      xvfb x11vnc novnc websockify openbox xterm \
      dbus-x11 at-spi2-core \
      libgtk-4-1 libglib2.0-bin libsqlite3-0 libx11-6 libxfixes3 libxtst6 \
      xclip x11-utils xdotool wmctrl imagemagick \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/*.deb /tmp/
# Install ALL THREE packages -- clipnest, clipnest-ocr, and
# clipnest-ocr-data -- not just the base `clipnest_*.deb` this glob used to
# match alone. clipnest only Recommends clipnest-ocr (never Depends, so a
# real end user can skip the ~22MB of vendored weights with
# --no-install-recommends), so this VNC test image has to opt in explicitly
# to actually exercise real OCR, which is the whole point of vendoring real
# weights (T-OCR9/T-OCR10). apt resolves the runtime deps dpkg-shlibdeps
# derived for each.
RUN apt-get update -qq \
    && apt-get install -y -qq /tmp/clipnest*.deb 2>&1 | tail -20 \
    && rm -rf /var/lib/apt/lists/* /tmp/*.deb
COPY packaging/linux/vnc/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
EXPOSE 6080
CMD ["/usr/local/bin/start.sh"]
