---
layout: article
title: Download Clipnest for Mac and Linux (Free)
description: Download Clipnest free for macOS 14 Sonoma and later, or Ubuntu 22.04/24.04 with GNOME. Open source, no account required.
permalink: /download/
---

# Download Clipnest

Free, open source, no account, no cloud, no telemetry. One command installs it on both the Mac and Linux: it detects your system and installs the latest version. Jump to [Linux](#linux).
{: .lead}

## Requirements

- **Mac:** macOS 14 (Sonoma) or later, Apple Silicon or Intel
- **Linux:** Ubuntu 22.04 or 24.04 with GNOME, X11 or Wayland, amd64 or arm64
{: .detail-list}

## Install on Mac

Run this in Terminal (the same command works on Linux, see below):

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

</div>

Clipnest installs into your Applications folder and launches. Look for its icon in the menu bar, then press **⌥⌘V** to open the picker.

The installer downloads over `curl` (which never sets macOS's quarantine flag, so there's no Gatekeeper "unidentified developer" dialog) and verifies the `.dmg` against a published SHA-256 checksum before ever mounting it — see [Signing, honestly](#signing-honestly) for why.

Prefer to grab the file yourself? Get the latest `.dmg` from the [GitHub Releases page](https://github.com/AayushGour/clipnest/releases), open it, and drag **Clipnest** into your Applications folder.

## Update on Mac

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
```

</div>

Updates Clipnest to the latest version, if a newer one is available. Same checksum verification as Install. You can also trigger this from inside the app: click the version number in the picker's footer (it shows a small dot when an update is available) and confirm — Clipnest opens Terminal and runs this exact script for you, then relaunches itself.

## Uninstall

One command for Mac and Linux:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/uninstall.sh | bash
```

</div>

It works on both macOS and Linux, removes the app and **keeps your history, snippets and settings**. Add `--purge` (`bash -s -- --purge`) to delete that data too; `CLIPNEST_DRY_RUN=1` shows what it would do without doing it. On Linux, `--purge` also removes the `clipnest-input` group, so log out and back in afterwards.

**Manual alternative on the Mac:** drag **Clipnest** from Applications to the Trash. To also remove its local data:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
rm -rf ~/Library/Application\ Support/Clipnest \
       ~/Library/Preferences/com.clipnest.app.plist \
       ~/Library/Caches/com.clipnest.app \
       ~/Library/HTTPStorages/com.clipnest.app
```

</div>

Everything Clipnest stores is local, so removing those paths leaves nothing behind.

## Signing, honestly (Mac)
{: #signing-honestly}

<div class="notice" markdown="1">

Clipnest is not distributed through the Mac App Store or a notarized, Developer-ID-signed `.dmg` by default. The supported install path (`scripts/install.sh` / `scripts/update.sh`) downloads with `curl`, which never sets the `com.apple.quarantine` flag — that flag, not the code signature, is what triggers Gatekeeper's "unidentified developer" check and its notarization gate, so a browser-downloaded copy would need it and a `curl`-installed one doesn't. In place of Gatekeeper, those scripts verify the `.dmg` against a SHA-256 checksum published alongside every release, and refuse to install anything unverifiable.

Every release is still signed — with one long-lived, self-signed certificate (`scripts/release-cert.sh`, run once ever), not a throwaway ad-hoc identity. That matters because macOS ties an Accessibility grant to the app's designated code requirement: an ad-hoc build gets a new one every build and would invalidate every user's grant on each update, while signing every release with the same certificate keeps the requirement — and the grant — stable across updates. This is **not** a Developer ID and does **not** enable notarization on its own; if the maintainer sets real Apple Developer ID + notary secrets in the repo, the release workflow signs and notarizes with those instead for a fully Gatekeeper-clean `.dmg`. Without them, releases ship a self-signed (not notarized) `.dmg`, verified the way described above.

None of this requires an Apple Developer account to build, run, or even distribute Clipnest via the supported curl-based install path — an account is only needed for the *optional* Gatekeeper-clean, notarized `.dmg` instead.

</div>

## Linux

Clipnest runs on **Ubuntu 22.04 and 24.04 with GNOME**, on X11 or Wayland, for amd64 and arm64.

### Install on Linux

Run the same command as on the Mac, as your normal user (not root):

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

</div>

The script checks that you're on Ubuntu 22.04 or 24.04 with GNOME, picks the amd64 or arm64 tarball for your CPU, downloads the latest release, verifies it against the SHA-256 GitHub publishes for that file (it stops if that is missing or different), checks the files inside with the bundled `SHA256SUMS`, and runs the bundled installer, which asks for your `sudo` password. On any other system it stops with a message; set `CLIPNEST_FORCE=1` to try anyway (unsupported). It needs `curl`, `tar`, `sha256sum` (or `shasum`), `sudo` and `apt-get`. Set `CLIPNEST_DRY_RUN=1` to do everything except the install.

**Prefer to do it by hand?** Download `clipnest-<version>-linux-amd64.tar.gz` (or `-arm64`; run `uname -m` if unsure: `x86_64` is amd64, `aarch64` is arm64) from the [latest release](https://github.com/AayushGour/clipnest/releases/latest), then:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
tar xzf clipnest-*-linux-amd64.tar.gz
cd clipnest-*-linux-amd64
sha256sum -c SHA256SUMS
./install.sh          # as your normal user, not with sudo
```

</div>

The bundled `install.sh` checks the architecture and installs three packages with `apt`: `clipnest`, plus `clipnest-ocr` and `clipnest-ocr-data` for text recognition in images. To skip OCR (about 26 MB), install only the app: `sudo apt-get install --no-install-recommends ./clipnest_*.deb`.

### First run on Linux

- Open the picker with **Alt+Super+V**; expand a snippet with **Alt+Super+E**. Both are rebindable in Settings → Shortcuts.
- **Auto-paste** needs a one-time permission. Clipnest offers it on first launch, or use Settings → Permissions. It adds you to a dedicated `clipnest-input` group that can create a virtual keyboard and nothing else (not the `input` group, which could read your keystrokes). Log out and back in afterwards. Until then Clipnest copies your choice and you press Ctrl+V yourself.
- **Start at login** is off by default. Nothing is captured while Clipnest isn't running, so turn on Settings → General → *Launch Clipnest at login*.
- **Optional GNOME Shell extension.** GNOME doesn't let apps place their own windows on Wayland, so the picker opens where GNOME puts it. The extension restores opening at your cursor and above full-screen windows (GNOME 45+; use `legacy` instead of `esm` on 42–44), then log out and back in:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
gnome-extensions install --force /usr/share/clipnest/gnome-shell-extension/esm
```

</div>

### Update and uninstall on Linux

To update, run the install command again (it installs the latest release over the current one), or download the newer tarball and run its `install.sh`. Or use Settings → General → **Check for Updates Now**: for a tarball install, Clipnest can download, checksum-verify and install the update for you after you confirm with **Install Update…** — it never installs anything on its own.

To uninstall, run the one-line command from [Uninstall](#uninstall) above. Or by hand:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
sudo apt remove clipnest clipnest-ocr clipnest-ocr-data
```

</div>

Your history in `~/.local/share/Clipnest` is left in place; delete that folder too to remove everything.

## Build from source

For contributors and anyone who'd rather not run a piped install script — clone the repo and build it yourself: with Xcode/XcodeGen on the Mac ([steps](https://github.com/AayushGour/clipnest#build-from-source)), or inside the official Swift Docker image on Linux ([steps](https://github.com/AayushGour/clipnest#build-from-source-linux)).

<div class="cta-inline" markdown="1">

Once it's installed, see the [usage guide]({{ '/usage/' | relative_url }}) to get productive, or check [Features]({{ '/features/' | relative_url }}) for everything Clipnest can do.

</div>
