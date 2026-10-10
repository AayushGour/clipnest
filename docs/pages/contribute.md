---
layout: article
title: Contribute to Clipnest — Manual Install, Updating and Building from Source
description: Advanced Clipnest details for contributors and power users — manual install with checksums, installer options, updating, Mac signing explained, the Linux GNOME extension, building from source, and how to report bugs or send a pull request.
permalink: /contribute/
---

# Contribute

The details behind the one-line install, plus how to build Clipnest and help improve it. If you just want to use Clipnest, the [Download page]({{ '/download/' | relative_url }}) is all you need.
{: .lead}

<nav class="box-grid" aria-label="On this page" markdown="1">

<p class="eyebrow">On this page</p>

- [Manual install](#manual-install)
- [Installer options](#installer-options)
- [Updating](#updating)
- [Uninstalling by hand](#uninstalling-by-hand)
- [Signing, honestly (Mac)](#signing-honestly)
- [Linux details](#linux)
- [Build from source](#build-from-source)
- [Report a bug or send a PR](#report-a-bug-or-send-a-pr)

</nav>

## Manual install
{: #manual-install}

Prefer not to pipe a script into a shell? Download the release yourself from [GitHub Releases](https://github.com/AayushGour/clipnest/releases/latest) and verify it first.

### macOS

Download `Clipnest-<version>.dmg` and its `Clipnest-<version>.dmg.sha256` into the same folder, then check the checksum before you open anything:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · macOS</b></div>

```bash
shasum -a 256 -c Clipnest-*.dmg.sha256
```

</div>

It should print `OK`. Open the `.dmg` and drag **Clipnest** into Applications. A browser download is quarantined by macOS, so the first launch shows an "unidentified developer" warning: Control-click Clipnest in Applications, choose **Open**, then click **Open** again. Or clear the flag once:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · macOS</b></div>

```bash
xattr -dr com.apple.quarantine /Applications/Clipnest.app
```

</div>

### Linux

Download `clipnest-<version>-linux-amd64.tar.gz` (or `-arm64`; run `uname -m` if unsure: `x86_64` is amd64, `aarch64` is arm64), then:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · Linux</b></div>

```bash
tar xzf clipnest-*-linux-amd64.tar.gz
cd clipnest-*-linux-amd64
sha256sum -c SHA256SUMS
./install.sh          # as your normal user, not with sudo
```

</div>

The bundled `install.sh` checks the architecture and installs three packages with `apt`: `clipnest`, plus `clipnest-ocr` and `clipnest-ocr-data` for text recognition in images. To skip OCR (about 26 MB), install only the app: `sudo apt-get install --no-install-recommends ./clipnest_*.deb`.

## Installer options
{: #installer-options}

Set these in front of `bash` to change how the one-line installer behaves, for example:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal</b></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | CLIPNEST_DRY_RUN=1 bash
```

</div>

<div class="table-scroll" markdown="1">

| Option | Applies to | What it does |
|---|---|---|
| `CLIPNEST_DRY_RUN=1` | `install.sh`, `uninstall.sh` | Do everything except the actual change: detect, download and verify for install; print each action for uninstall. |
| `CLIPNEST_FORCE=1` | `install.sh`, Linux | Continue on a system that isn't Ubuntu 22.04/24.04 with GNOME. Unsupported; it may not work. |
| `GITHUB_TOKEN` | `install.sh`, `update.sh` | A GitHub personal access token (no scopes needed for a public repo). Only raises the GitHub API rate limit from 60 to 5000 requests an hour per IP. Never printed or written to disk. |
| `REQUIRE_CHECKSUM=false` | `install.sh`, `update.sh`, macOS | By default the install stops if a release has no published checksum. `false` allows an unverified `.dmg` from an old release that predates checksums. Not recommended. A checksum mismatch always stops the install. |
| `--purge` or `CLIPNEST_PURGE=1` | `uninstall.sh` | Also delete your history, snippets and settings. Pass it as `bash -s -- --purge`. On Linux it also removes the `clipnest-input` group, so log out and back in afterwards. |

</div>

The installer needs `curl`, plus `tar`, `sha256sum` (or `shasum`), `sudo` and `apt-get` on Linux. On Linux it checks the tarball against the SHA-256 GitHub publishes for that release file (it stops if that is missing or different), then checks the files inside with the bundled `SHA256SUMS`.

## Updating
{: #updating}

On a Mac, run the update script. It installs the latest version if a newer one exists, with the same checksum verification as the installer:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · macOS</b></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
```

</div>

You can also click the version number in the picker footer (it shows a small dot when an update is available) and confirm: Clipnest opens Terminal, runs this script, then relaunches itself.

On Linux, run the install command again (it installs the latest release over the current one), or download the newer tarball and run its `install.sh`. Or use Settings → General → **Check for Updates Now**: for a tarball install, Clipnest can download, checksum-verify and install the update after you confirm with **Install Update…**. It never installs anything on its own.

## Uninstalling by hand
{: #uninstalling-by-hand}

**Mac:** drag **Clipnest** from Applications to the Trash. To also remove its local data:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · macOS</b></div>

```bash
rm -rf ~/Library/Application\ Support/Clipnest \
       ~/Library/Preferences/com.clipnest.app.plist \
       ~/Library/Caches/com.clipnest.app \
       ~/Library/HTTPStorages/com.clipnest.app
```

</div>

**Linux:**

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · Linux</b></div>

```bash
sudo apt remove clipnest clipnest-ocr clipnest-ocr-data
```

</div>

Your Linux history in `~/.local/share/Clipnest` is left in place; delete that folder too to remove everything.

## Signing, honestly (Mac)
{: #signing-honestly}

<div class="notice" markdown="1">

Clipnest is not distributed through the Mac App Store or a notarized, Developer-ID-signed `.dmg` by default. The supported install path (`scripts/install.sh` / `scripts/update.sh`) downloads with `curl`, which never sets the `com.apple.quarantine` flag — that flag, not the code signature, is what triggers Gatekeeper's "unidentified developer" check and its notarization gate, so a browser-downloaded copy would need it and a `curl`-installed one doesn't. In place of Gatekeeper, those scripts verify the `.dmg` against a SHA-256 checksum published alongside every release, and refuse to install anything unverifiable.

Every release is still signed — with one long-lived, self-signed certificate (`scripts/release-cert.sh`, run once ever), not a throwaway ad-hoc identity. That matters because macOS ties an Accessibility grant to the app's designated code requirement: an ad-hoc build gets a new one every build and would invalidate every user's grant on each update, while signing every release with the same certificate keeps the requirement — and the grant — stable across updates. This is **not** a Developer ID and does **not** enable notarization on its own; if the maintainer sets real Apple Developer ID + notary secrets in the repo, the release workflow signs and notarizes with those instead for a fully Gatekeeper-clean `.dmg`. Without them, releases ship a self-signed (not notarized) `.dmg`, verified the way described above.

None of this requires an Apple Developer account to build, run, or even distribute Clipnest via the supported curl-based install path — an account is only needed for the *optional* Gatekeeper-clean, notarized `.dmg` instead.

</div>

## Linux details
{: #linux}

Clipnest runs on **Ubuntu 22.04 and 24.04 with GNOME**, on X11 or Wayland, for amd64 and arm64.

- **Shortcuts.** Open the picker with **Alt+Super+V**; expand a snippet with **Alt+Super+E**. Both are rebindable in Settings → Shortcuts.
- **Auto-paste** needs a one-time permission. Clipnest offers it on first launch, or use Settings → Permissions. It adds you to a dedicated `clipnest-input` group that can create a virtual keyboard and nothing else (not the `input` group, which could read your keystrokes). Log out and back in afterwards. Until then Clipnest copies your choice and you press Ctrl+V yourself.
- **Start at login** is off by default. Nothing is captured while Clipnest isn't running, so turn on Settings → General → *Launch Clipnest at login*.
- **Optional GNOME Shell extension.** GNOME doesn't let apps place their own windows on Wayland, so the picker opens where GNOME puts it. The extension restores opening at your cursor and above full-screen windows (GNOME 45+; use `legacy` instead of `esm` on 42–44), then log out and back in:
{: .detail-list}

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal · Linux</b></div>

```bash
gnome-extensions install --force /usr/share/clipnest/gnome-shell-extension/esm
```

</div>

Logs: `journalctl --user -t app.clipnest.Clipnest` follows the app's log.

## Build from source
{: #build-from-source}

Clone the repo and build it yourself. The full steps, with every flag, are in the README: [build on the Mac](https://github.com/AayushGour/clipnest#build-from-source) (Xcode 16+ and XcodeGen) and [build on Linux](https://github.com/AayushGour/clipnest#build-from-source-linux) (inside the official Swift Docker image). The short version:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span><b class="terminal-label">Terminal</b></div>

```bash
git clone https://github.com/AayushGour/clipnest.git
cd clipnest
make test      # unit tests: swift test on a Mac, Docker on Linux
make build     # app build; run `make` to list every target
```

</div>

The core logic is a plain Swift package with no Xcode dependency, so most changes can be developed and tested from the command line. Run `make` on its own to see every target, including `make deb`, `make dmg` and `make lint`.

## Report a bug or send a PR
{: #report-a-bug-or-send-a-pr}

Issues, ideas and pull requests are welcome.

- **Found a bug?** [Open an issue](https://github.com/AayushGour/clipnest/issues/new) with your OS and version, the Clipnest version (shown in the picker footer), and what you did. On Linux, include the output of `journalctl --user -t app.clipnest.Clipnest`.
- **Want to change something?** Fork the repo, make your change with tests, and open a [pull request](https://github.com/AayushGour/clipnest/pulls). Before you do, run `scripts/lint.sh` (it needs Docker on most machines: it runs the exact swift-format build CI trusts).

<div class="cta-inline" markdown="1">

Back to the [Download page]({{ '/download/' | relative_url }}), the [usage guide]({{ '/usage/' | relative_url }}), or the [source on GitHub](https://github.com/AayushGour/clipnest).

</div>
