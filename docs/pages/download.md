---
layout: default
title: Download Clipnest for macOS (Free)
description: Download Clipnest free for macOS 14 Sonoma and later. Open source, no account required — one command to install.
permalink: /download/
---

# Download Clipnest

Free, open source, no account, no cloud, no telemetry. One command installs it.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel

## Install

Run this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

Clipnest installs into your Applications folder and launches. Look for its icon in the menu bar, then press **⌥⌘V** to open the picker.

The installer downloads over `curl` (which never sets macOS's quarantine flag, so there's no Gatekeeper "unidentified developer" dialog) and verifies the `.dmg` against a published SHA-256 checksum before ever mounting it — see [Signing, honestly](#signing-honestly) for why.

Prefer to grab the file yourself? Get the latest `.dmg` from the [GitHub Releases page](https://github.com/AayushGour/clipnest/releases), open it, and drag **Clipnest** into your Applications folder.

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
```

Updates Clipnest to the latest version, if a newer one is available. Same checksum verification as Install. You can also trigger this from inside the app: click the version number in the picker's footer (it shows a small dot when an update is available) and confirm — Clipnest opens Terminal and runs this exact script for you, then relaunches itself.

## Uninstall

Drag **Clipnest** from Applications to the Trash. To also remove its local data:

```bash
rm -rf ~/Library/Application\ Support/Clipnest \
       ~/Library/Preferences/com.clipnest.app.plist
```

Everything Clipnest stores is local, so removing those two paths leaves nothing behind.

## Signing, honestly

Clipnest is not distributed through the Mac App Store or a notarized, Developer-ID-signed `.dmg` by default. The supported install path (`scripts/install.sh` / `scripts/update.sh`) downloads with `curl`, which never sets the `com.apple.quarantine` flag — that flag, not the code signature, is what triggers Gatekeeper's "unidentified developer" check and its notarization gate, so a browser-downloaded copy would need it and a `curl`-installed one doesn't. In place of Gatekeeper, those scripts verify the `.dmg` against a SHA-256 checksum published alongside every release, and refuse to install anything unverifiable.

Every release is still signed — with one long-lived, self-signed certificate (`scripts/release-cert.sh`, run once ever), not a throwaway ad-hoc identity. That matters because macOS ties an Accessibility grant to the app's designated code requirement: an ad-hoc build gets a new one every build and would invalidate every user's grant on each update, while signing every release with the same certificate keeps the requirement — and the grant — stable across updates. This is **not** a Developer ID and does **not** enable notarization on its own; if the maintainer sets real Apple Developer ID + notary secrets in the repo, the release workflow signs and notarizes with those instead for a fully Gatekeeper-clean `.dmg`. Without them, releases ship a self-signed (not notarized) `.dmg`, verified the way described above.

None of this requires an Apple Developer account to build, run, or even distribute Clipnest via the supported curl-based install path — an account is only needed for the *optional* Gatekeeper-clean, notarized `.dmg` instead.

## Build from source

For contributors and anyone who'd rather not run a piped install script — clone the repo and build it yourself with Xcode/XcodeGen. See the [`README`](https://github.com/AayushGour/clipnest#build-from-source) for the full step-by-step.

---

Once it's installed, see the [usage guide]({{ '/usage/' | relative_url }}) to get productive, or check [Features]({{ '/features/' | relative_url }}) for everything Clipnest can do.
