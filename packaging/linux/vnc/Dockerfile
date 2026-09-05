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
# OCR is compiled out in this image (no -DCLIPNEST_HAS_ONNXRUNTIME, see D66),
# so the PP-OCRv5 models are inert here. debian/rules correctly refuses to
# package without them, which is the right default -- so place zero-byte
# stand-ins INSIDE the container only. The repo keeps no fake models, and the
# clipnest-ocr-data package produced by this image is deliberately empty and
# must never be published.
RUN mkdir -p packaging/linux/vendor/ppocr-models \
    && for f in det.onnx rec.onnx cls.onnx dict.txt; do \
         : > "packaging/linux/vendor/ppocr-models/$f"; done
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
# Install our packages; apt resolves the runtime deps dpkg-shlibdeps derived.
RUN apt-get update -qq \
    && apt-get install -y -qq /tmp/clipnest_*.deb 2>&1 | tail -20 \
    && rm -rf /var/lib/apt/lists/* /tmp/*.deb
COPY packaging/linux/vnc/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
EXPOSE 6080
CMD ["/usr/local/bin/start.sh"]
