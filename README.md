<div align="center">

<img src="clipnest-logo-main.svg" alt="Clipnest logo" width="140" />

# Clipnest — a fast, private clipboard manager for Mac

**Never lose a copy again.** Clipnest is a lightweight, native **macOS clipboard manager** that quietly remembers everything you copy — text, links, images, and files — and hands it back the instant you need it. Hit a hotkey, search, paste.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![Built with SwiftUI](https://img.shields.io/badge/built%20with-Swift%20%26%20SwiftUI-orange)](#how-its-built)
[![Local only](https://img.shields.io/badge/privacy-100%25%20local-brightgreen)](#privacy-first)
[![License: MIT](https://img.shields.io/badge/license-MIT-black)](LICENSE)

</div>

---

## Why Clipnest?

macOS only remembers the **last** thing you copied. Copy something new and the old one is gone forever — the link you needed, the code snippet, the address you just had. A good **clipboard history manager** fixes that, and once you have one you'll wonder how you lived without it.

Clipnest is built to be the one you actually keep running: **native, tiny, instant, and completely private.** No Electron, no web view, no account, no cloud, no telemetry. Just a clean menu-bar app that does one job extremely well.

> Looking for a **free, open-source clipboard manager for Mac** — a lightweight alternative to Paste, Maccy, or Pastebot? Clipnest is a fresh, from-scratch take built in pure SwiftUI.

## Features

- 📋 **Full clipboard history** — automatically captures everything you copy: plain text, rich text, URLs, images, and files.
- ⚡ **Global hotkey** — press **⌥⌘V** anywhere to pop the picker open right at your cursor, over any app (even full-screen).
- 🔎 **Instant search** — start typing to filter your entire copy-paste history in real time.
- ↩︎ **Paste into your active app** — pick an item and, with Accessibility permission granted, Clipnest types it straight into the field you were using; otherwise it's placed on your clipboard to paste yourself.
- 📌 **Pin your favorites** — keep the items you reuse most pinned to the top, always a keystroke away.
- 🗑 **Prune easily** — delete anything you don't want to keep.
- 🧠 **Smart de-duplication** — copy the same thing twice and it won't clutter your history.
- ⌨️ **Keyboard-first** — arrows to move, Return to paste, Esc to dismiss, ⌘F to search, ⌘P to pin, ⌘⌫ to delete.
- 🪶 **Featherweight & native** — pure Swift/SwiftUI, a few MB, sips almost no memory, feels like part of macOS.
- 🔒 **Private by design** — everything stays on your Mac. See [Privacy](#privacy-first).

## Privacy first

Your clipboard is some of the most sensitive data on your machine — passwords, tokens, private messages. Clipnest treats it that way:

- **100% local.** Nothing ever leaves your Mac. No servers, no sync, no analytics, no network calls at all.
- **Password managers are ignored.** Clipnest honors the standard "concealed" and "transient" clipboard markers, so copies from 1Password, Bitwarden, and friends are never stored.
- **You're in control.** Pause capturing anytime, or clear your whole history in one click.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel

## Install

### Download (recommended)

Grab the latest signed, notarized `.dmg` from the [**Releases**](../../releases) page, drag Clipnest to your Applications folder, and launch it. *(The release pipeline that builds, signs, and notarizes that `.dmg` is documented below in [Release](#release) — the first signed build depends on the maintainer's own Apple Developer account being wired up.)*

### Build from source

```bash
# 1. Tooling (one-time)
brew install xcodegen        # requires Xcode 15+ installed

# 2. Clone
git clone https://github.com/<your-username>/clipnest.git
cd clipnest

# 3. Generate the Xcode project and build
cd ClipnestApp
xcodegen generate
xcodebuild -scheme ClipnestApp -configuration Release build

# Core logic is a Swift package you can test on its own:
cd .. && swift test
```

On first launch, grant Clipnest **Accessibility** access (System Settings → Privacy & Security → Accessibility) so it can paste into other apps. Everything else works without it.

## Release

The `.dmg` on the [Releases](../../releases) page is produced by four small, chained shell scripts in [`scripts/`](scripts/) — no CI platform, just local scripts anyone with a Developer ID can run:

```bash
scripts/build.sh          # xcodegen generate → xcodebuild archive → exports Clipnest.app to build/
scripts/sign.sh   "<identity>"   # codesign --sign "<identity>" build/Clipnest.app
scripts/notarize.sh "<profile>"  # zips, submits to notarytool --wait, staples the ticket
scripts/package_dmg.sh    # wraps create-dmg (or an hdiutil fallback) → build/Clipnest.dmg
```

`build.sh` never needs a signing identity — it always produces a runnable `build/Clipnest.app` on its own, so it's safe to run at any time (e.g. to smoke-test a change). `sign.sh` and `notarize.sh` genuinely need a Developer ID:

- **`sign.sh`** takes the codesign identity as its first argument or `$CODESIGN_IDENTITY` — never hardcoded. Find yours with `security find-identity -v -p codesigning`.
- **`notarize.sh`** takes an `xcrun notarytool` keychain profile name as its first argument or `$NOTARY_PROFILE`. Set that profile up **once**, out-of-band, on your own machine — it stores your Apple ID/password in your login keychain, never in this repo:
  ```bash
  xcrun notarytool store-credentials "<profile-name>" \
    --apple-id "<your-apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>"
  ```
- `ClipnestApp/project.yml`'s Release config reads `DEVELOPMENT_TEAM`/`CODE_SIGN_IDENTITY` from the environment too (via XcodeGen's `${VAR}` expansion), so exporting `DEVELOPMENT_TEAM` before `scripts/build.sh` gets you a proper `-exportArchive` (method: `developer-id`) instead of the plain unsigned copy out of the archive.

None of this requires an Apple Developer account to build and run Clipnest from source — it's only needed to produce a Gatekeeper-clean, distributable `.dmg` (see [Build from source](#build-from-source) above for the account-free path).

## Usage

1. Clipnest lives in your **menu bar** — no Dock clutter.
2. Copy things like you normally would; Clipnest remembers them.
3. Press **⌥⌘V** (or click the menu-bar icon → *Open Clipnest*) to open the picker.
4. **Type** to search, **↑/↓** to move, **Return** to paste into whatever you were doing.
5. **Pin** the ones you reuse most and forget about ever losing a copy again.

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open Clipnest | `⌥⌘V` |
| Search | `⌘F` |
| Move selection | `↑` / `↓` |
| Paste selected | `Return` |
| Pin / unpin | `⌘P` |
| Delete entry | `⌘⌫` |
| Close | `Esc` |

## How it's built

Clipnest is intentionally boring in the best way — a small, well-tested native codebase:

- **Swift 6 + SwiftUI/AppKit**, minimum macOS 14.
- **`ClipnestCore`** — a dependency-light Swift package holding all the logic (capture, privacy filtering, storage, search, paste), covered by a full unit-test suite.
- **SwiftData** for local persistence; content-addressed blob storage for images/files.
- **One dependency:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) for the global hotkey. That's it.

Extending Clipnest or building your own frontend on top of `ClipnestCore`?
See **[`docs/API.md`](docs/API.md)** for the full public API reference —
every type, function, and error case, plus a working end-to-end example.

## Roadmap

- [ ] Notarized `.dmg` release + auto-updates
- [ ] Rich previews for images and files in the list
- [ ] Configurable retention (keep N days / N items)
- [ ] Custom hotkey rebinding + launch-at-login in Settings

## Contributing

Issues, ideas, and pull requests are welcome. Clipnest is a small, readable codebase built to be hacked on — clone it, run `swift test`, and dive in.

## License

Clipnest is released under the [MIT License](LICENSE) — free to use, modify, and share.

---

<div align="center">
<sub><strong>Clipnest</strong> · a free, open-source, native clipboard history manager for macOS · clipboard manager · copy-paste history · Mac productivity</sub>
</div>
