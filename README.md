<div align="center">

<img src="assets/clipnest-icons/clipnest-logo.png" alt="Clipnest logo" width="150" />

# Clipnest — a fast, private clipboard manager for Mac

**Never lose a copy again.** Clipnest is a lightweight, native **macOS clipboard manager** that quietly remembers everything you copy — text, links, images, and files — and hands it back the instant you need it. Hit a hotkey, search, paste. Plus reusable **snippets** you can expand by keyword in any app, and a full **Settings window** to make it yours.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![Built with SwiftUI](https://img.shields.io/badge/built%20with-Swift%20%26%20SwiftUI-orange)](#how-its-built)
[![Local only](https://img.shields.io/badge/privacy-100%25%20local-brightgreen)](#privacy-first)
[![License: MIT](https://img.shields.io/badge/license-MIT-black)](LICENSE)

</div>

---

<!-- TODO(T78): add site link once Pages is live -->

## Why Clipnest?

macOS 26 Tahoe added a basic clipboard history to Spotlight (⌘4) — but it's opt-in, caps out at 7 days, and can't organize, pin, or expand anything. Clipnest is a free, open-source, native menu-bar app that picks up where that leaves off: history you control, instant search, pinned favorites, and reusable snippets that expand by keyword in any app.

**Update Clipnest and you don't have to re-grant Accessibility — your permission survives, because every release is signed with the same certificate.** Most apps that rebuild or re-sign between versions quietly invalidate that grant, so a routine update leaves you back in System Settings, re-adding the app by hand. Clipnest doesn't do that to you, by design — see [Signing, honestly](#release) for exactly how.

It's free and open source, built in pure SwiftUI/AppKit — no Electron, no web view, no account, no cloud, no telemetry. And its **snippets** expand by keyword in any app, so a reusable signature, boilerplate, or command replaces your text expander too, not just your clipboard history — see [Snippets & keyword expansion](#snippets--keyword-expansion).

> Looking for a **free, open-source clipboard manager for Mac** — a lightweight alternative to Paste, Maccy, or Pastebot? Clipnest is a fresh, from-scratch take built in pure SwiftUI.

## Features

- 📋 **Full clipboard history** — automatically captures everything you copy: plain text, rich text, URLs, images, and files.
- 🛡 **Accessibility permission survives updates** — update Clipnest and you don't have to re-grant Accessibility: your permission survives, because every release is signed with the same certificate (see [Signing, honestly](#release)).
- ⚡ **Global hotkey** — press **⌥⌘V** anywhere to pop the picker open right at your cursor, over any app (even full-screen).
- 🔎 **Instant search** — start typing to filter your entire copy-paste history in real time, with matches highlighted.
- 🏷 **Type filters** — narrow the list to just text, images, files, or links with one click.
- 🗂 **Tabs** — **History**, **Pinned**, and **Snippets**, switchable with ⌘1 / ⌘2 / ⌘3.
- ↩︎ **Paste into your active app** — pick an item and, with Accessibility granted, Clipnest types it straight into the field you were using; otherwise it's placed on your clipboard to paste yourself.
- 🅰 **Paste without formatting** — **⌥Return** only differs from plain **Return** where there's actually something to strip: on **rich text** items it pastes the plain-text form instead of the formatted one, and on an **image row with recognized text** (see OCR below) it pastes that recognized text instead of the image. On plain text, links, files, and images with no recognized text, ⌥Return pastes exactly what Return does — there's nothing richer to strip.
- 🔍 **On-device text recognition (OCR), off by default** — let Clipnest read the text in your screenshots so you can find them by what they say, not just when you copied them. Turn it on in Settings → History; see [Privacy](#privacy-first) for the trade-off before you do.
- 👁 **Hover previews** — hover (or arrow to) an item and a popover shows the full content: the image at up to 40% of screen width (with any recognized text shown below it), the full scrollable text (loaded in chunks for huge clips), or a file's name, size, and path.
- 📌 **Pin your favorites** — keep the items you reuse most pinned to the top, always a keystroke away.
- 🧠 **Smart de-duplication** — copy the same thing twice and it won't clutter your history.
- ✂️ **Snippets** — save reusable text (a signature, boilerplate, a command) with a **Tag**, and paste it from the Snippets tab or **expand it by keyword in any app** (see below) — replaces your text expander too. Turn a text or link history item into a snippet with **⌘S** — the only kinds ⌘S applies to, since those are the only ones with a plain-text body to seed one from.
- ⚙️ **A real Settings window** — General, History, Apps, Shortcuts, and Permissions tabs to tune Clipnest to how you work (see below). Open it from the menu-bar icon → *Settings…*, or with **⌘,**.
- ⌨️ **Keyboard-first** — arrows to move, Return to paste, Esc to dismiss, ⌘F to search, ⌘P to pin, ⌘⌫ to delete, ⌘1/2/3 for tabs, ⌘, for Settings.
- 🪶 **Featherweight & native** — pure Swift/SwiftUI, a few MB, sips almost no memory, feels like part of macOS. Lives in the menu bar with no Dock icon day-to-day (opening Settings briefly shows one — see [Settings](#settings)).
- 🔒 **Private by design** — everything stays on your Mac. See [Privacy](#privacy-first).

## Snippets & keyword expansion

Snippets are reusable bits of text you author yourself (unlike captured history). Create one in the **Snippets** tab (⌘N) or save any history item as a snippet (⌘S). Each snippet has a **Tag** (its name — also its expansion keyword) and a **Body** (what gets pasted). If you're running a separate text expander alongside your clipboard manager today, this replaces it — one keyword-expansion engine, built in, that works in every app.

**Expand anywhere:** type a snippet's Tag in *any* app, select it, and press **⌥⌘E** — Clipnest replaces the selection with the snippet's Body.

It works in **every** application, using a two-tier approach:

1. **Accessibility first** — in native / most Cocoa text fields, it reads and replaces the selection directly, without ever touching your clipboard.
2. **Clipboard fallback** — where the Accessibility API can't read the selection (Electron/Chrome apps like VS Code, Slack), it synthesizes copy/paste — which every app supports — while **snapshotting and restoring your clipboard** so it's left exactly as it was, and suppressing Clipnest's own capture of the transient copy/paste.

No keyword match, or nothing selected → a gentle system beep, nothing changed.

## Settings

Everything about how Clipnest behaves lives in one Settings window, across five tabs. Open it from the menu-bar icon → *Settings…*, or press **⌘,** while the picker or the Settings window itself is focused — deliberately not a global hotkey, so it never takes ⌘, away from whatever other app you're using (that app's own shortcut keeps working normally). One side effect worth knowing: opening Settings briefly shows Clipnest's Dock icon — macOS won't bring a menu-bar-only app's window to the front without one — and it disappears again once you close the window.

- **General** — launch Clipnest at login, pause clipboard capture with one toggle, and turn the background update check on/off.
- **History** — controls how much history is kept. The default is the most recent **1,000** items; switch to a day-based cap (30 days by default) or *Everything* (no cap at all) instead. Pinned items are always kept regardless of the cap. **Clear All History…** wipes everything (including pinned items) after a confirmation. This tab also has **"Recognize text in copied images"** — optional on-device OCR, **off by default**, with a **Fast**/**Accurate** (default) quality choice (see [Privacy](#privacy-first) for why it's off by default).
- **Apps** — exclude specific apps from capture, on top of the built-in password-manager denylist (which can't be removed). Add an app by picking its `.app` bundle.
- **Shortcuts** — rebind *both* global hotkeys (open the picker, expand a snippet) to whatever key combination you want.
- **Permissions** — see whether Accessibility is granted and fix it in one click, including guidance for the one case System Settings can't diagnose on its own (a rebuilt/updated app whose old permission entry no longer matches).

## Privacy first

Your clipboard is some of the most sensitive data on your machine — passwords, tokens, private messages. Clipnest treats it that way:

- **100% local, with one narrow exception.** Nothing you copy, paste, or save as a snippet is ever sent anywhere — no servers, no sync, no analytics, no telemetry, no account. The *only* network traffic Clipnest ever makes is a background check against GitHub's public Releases API (once a day, toggle it off in Settings → General) to see whether a newer version exists — it sends nothing about you or your clipboard, just an anonymous request for the latest release tag. Nothing downloads or installs automatically from that check; updating is a separate, manual step you choose to run (see [Update](#update)).
- **On-device text recognition is opt-in, and it's a real trade-off — here it is, plainly.** Turn on "Recognize text in copied images" (Settings → History, **off by default**) and Clipnest reads the text in a screenshot right on your Mac using Apple's Vision framework — no upload, no model download, no network call of any kind. But that recognized text becomes plain, searchable text stored alongside the image, so a screenshot containing a password, a token, or anything else sensitive turns that content into indexed text on disk. That's exactly why this is off by default rather than on — turn it on only if you're fine with that trade-off. It never runs on anything the pasteboard-privacy checks already rejected: concealed/transient (password-manager) copies and content from excluded apps are filtered out before an item is even captured, so text recognition never sees them.
- **Password managers are ignored.** Clipnest honors the standard "concealed" and "transient" clipboard markers, so copies from 1Password, Bitwarden, and friends are never stored — a rule no setting can override.
- **No content in logs.** Only metadata (ids, error cases) is ever logged, never clipboard or snippet contents.
- **You're in control.** Delete any entry on the spot with `⌘⌫`, pause capture whenever you want, and clear your entire history in one click — all from [Settings](#settings).

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel
- Xcode 16+ (Swift 6 toolchain) to build the app — but **Xcode 26+ to run `swift test`**: the SwiftData test suite crashes on Xcode 16.x with `Unable to determine Bundle Name` in a hostless package test target, so CI (and the release build) run on Xcode 26.
- **Accessibility** permission (optional) — only needed for pasting into other apps, expanding snippets, and the global hotkey firing from other apps; capturing and searching work without it.

## Install

Run this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

Clipnest installs into your Applications folder and launches. Look for its icon
in the menu bar, then press **⌥⌘V** to open the picker.

The installer downloads over `curl` (which never sets macOS's quarantine flag, so there's no Gatekeeper "unidentified developer" dialog) and verifies the `.dmg` against a published SHA-256 checksum before ever mounting it — see [Release](#release) for why.

### Update

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
```

Updates Clipnest to the latest version, if a newer one is available. Same checksum verification as Install. You can also trigger this from inside the app: click the version number in the picker's footer (it shows a small dot when an update is available) and confirm — Clipnest opens Terminal and runs this exact script for you, then relaunches itself.

### Build from source

```bash
# 1. Tooling (one-time): install XcodeGen — see
#    https://github.com/yonaskolb/XcodeGen#installing  (requires Xcode 16+)

# 2. Clone
git clone https://github.com/AayushGour/clipnest.git
cd clipnest

# 3. Test the core logic (pure Swift package, no Xcode project needed — needs Xcode 26+; see Requirements)
swift test

# 4. Generate the Xcode project and build the app
cd ClipnestApp
xcodegen generate
xcodebuild -project ClipnestApp.xcodeproj -scheme ClipnestApp \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# 5. Run it
open DerivedData/Build/Products/Debug/Clipnest.app   # if built with -derivedDataPath DerivedData
```

On first launch, grant Clipnest **Accessibility** access (System Settings → Privacy & Security → Accessibility) so it can paste into other apps, expand snippets, and fire the global hotkey from other apps. Everything else works without it.

An unsigned dev build's code identity changes on every rebuild, which normally makes macOS drop the Accessibility grant each time — `scripts/dev-cert.sh` (run once) plus `scripts/dev-install.sh` (build + sign + install with that stable local identity, instead of steps 4–5 above) fixes that: rebuild as often as you like without re-granting.

## Uninstall

Drag **Clipnest** from Applications to the Trash. To also remove its local data:

```bash
rm -rf ~/Library/Application\ Support/Clipnest \
       ~/Library/Preferences/com.clipnest.app.plist
```

Everything Clipnest stores is local, so removing those two paths leaves nothing behind.

## Usage

1. Clipnest lives in your **menu bar** — no Dock clutter day-to-day (opening Settings is the one exception; see [Settings](#settings)).
2. Copy things like you normally would; Clipnest remembers them.
3. Press **⌥⌘V** (or click the menu-bar icon → *Open Clipnest*) to open the picker at your cursor.
4. **Type** to search, **↑/↓** to move, **Return** to paste into whatever you were doing.
5. **Pin** the ones you reuse most, save handy text as **Snippets**, and expand them anywhere with **⌥⌘E**.
6. Tune capture, retention, excluded apps, and shortcuts any time from **Settings** (menu-bar icon → *Settings…*, or **⌘,**).

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open Clipnest | `⌥⌘V` |
| Expand snippet by Tag (in any app) | `⌥⌘E` |
| Search | `⌘F` |
| Move selection | `↑` / `↓` |
| Paste selected | `Return` |
| Paste without formatting *(rich text → plain; recognized-text images → that text)* | `⌥Return` |
| Pin / unpin | `⌘P` |
| Save history item as snippet *(text/link items only)* | `⌘S` |
| New snippet (Snippets tab) | `⌘N` |
| Delete entry | `⌘⌫` |
| Switch tabs (History / Pinned / Snippets) | `⌘1` / `⌘2` / `⌘3` |
| Open Settings *(picker or Settings window focused — not global)* | `⌘,` |
| Close | `Esc` |

Both the picker hotkey and the snippet-expansion hotkey are rebindable in Settings → Shortcuts; ⌥⌘V / ⌥⌘E above are just the defaults. **⌥Return** only behaves differently from plain **Return** where there's actually something to strip: on **rich text** items it pastes the plain-text form instead of the formatted one, and on an **image row with recognized text** (OCR — see [Settings](#settings)) it pastes that text instead of the image, falling back to pasting the image itself if nothing was recognized. On plain text, links, files, and images with no recognized text, ⌥Return pastes exactly what Return does — there's no richer form to strip. An image also gets a "Copy Recognized Text" action in its right-click menu when it has recognized text, alongside a small badge on its thumbnail. **⌘S** saves a highlighted text or link item as a snippet; it's a no-op on image, rich-text, and file rows, matching those rows' own UI, which never offers a "Save as Snippet" action there. **⌘,** opens Settings while the picker is focused (closing the picker first, then opening and focusing Settings) or while the Settings window itself is already focused — it's deliberately not a global hotkey, so pressing it from any other app does nothing and never steals that app's own ⌘, shortcut.

## How it's built

Clipnest is intentionally boring in the best way — a small, well-tested native codebase split into a pure-logic package and a thin UI shell:

- **Swift 6 + SwiftUI/AppKit**, minimum macOS 14. Menu-bar app (`LSUIElement`, no Dock icon).
- **`ClipnestCore`** — a dependency-light Swift package holding *all* the logic (capture, privacy filtering, storage, search, paste, snippet expansion, OCR). Fully unit-tested with Swift Testing — runnable on its own with `swift test`, no Xcode project required.
- **`ClipnestApp`** — the SwiftUI/AppKit frontend (menu bar, the non-activating floating picker panel, hover-preview popover, snippet editor window, Settings window). Generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ClipnestApp/project.yml`.
- **Persistence:** **SwiftData** for metadata; a content-addressed **blob store** on disk for image/rich-text bytes (deduped by SHA-256), so the database stays small.
- **Capture:** macOS has no "pasteboard changed" event, so a lightweight `changeCount` poll detects new copies; a live hook pushes them straight into the picker.
- **Paste & expansion:** synthesized ⌘V via `CGEvent`; snippet expansion uses an **Accessibility path** with a **clipboard-with-restore fallback** so it works in every app (see [Snippets](#snippets--keyword-expansion)).
- **On-device OCR (optional, off by default):** Apple's **Vision** framework (`VNRecognizeTextRequest`) recognizes text in a copied image entirely on-device — no model download, no network call, no new third-party dependency. Recognition quality is a Settings → History choice, **Fast** or **Accurate** (default), trading a small latency difference for materially better digit/punctuation/arrow accuracy. Images are downscaled to a 1,600pt long edge before recognition runs, and anything over 50 MB or 20,000px on a side is skipped outright. Runs only at the moment of capture (never a background sweep) and only on images the privacy filter already admitted; recognized text is folded into the same search index as everything else. See [Settings](#settings) and [Privacy](#privacy-first).
- **Focus-safe UI:** the picker is a non-activating `NSPanel` so it never steals keyboard focus from the app you were using; the preview popover is a separate non-key panel beside it.
- **One dependency:** [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (MIT) for global-hotkey registration. Everything else is system frameworks.

**Documentation:**

- **[`docs/architecture.md`](docs/architecture.md)** — system architecture, module reference, data-flow & concurrency diagrams.
- **[`docs/features.md`](docs/features.md)** — how each feature is implemented, file-by-file.
- **[`docs/usage.md`](docs/usage.md)** — full end-user guide.
- **[`docs/API.md`](docs/API.md)** — public `ClipnestCore` API reference. _(Being refreshed — parts lag the current code; check the source under `Sources/ClipnestCore` for anything load-bearing.)_
- **[`docs/review/`](docs/review/)** — architecture / code / implementation review reports.

### Project structure

```
.
├── Package.swift               # ClipnestCore Swift package (logic + tests)
├── Sources/ClipnestCore/
│   ├── Model/                  # ClipItem, Snippet, ItemKind (+ preview eligibility)
│   ├── Clipboard/              # ClipboardMonitor, PasteboardReader, PrivacyFilter
│   ├── Store/                  # ClipStore/SnippetStore protocols, SwiftData + in-memory impls, BlobStore
│   ├── Search/                 # SearchQuery, SearchHighlighter
│   ├── OCR/                    # TextRecognizing protocol + VisionTextRecognizer (on-device, optional)
│   └── Paste/                  # Paster, EventSynthesizing, SnippetExpander, SelectedTextAccessing, SelectionReplacing
├── Tests/ClipnestCoreTests/    # Swift Testing suites for the whole core
├── ClipnestApp/
│   ├── project.yml             # XcodeGen project definition
│   ├── Resources/Assets.xcassets   # AppIcon + MenuBarIcon
│   └── Sources/
│       ├── App/                 # @main, AppDelegate, AppEnvironment (composition root)
│       ├── System/               # HotkeyManager, PermissionsManager, SettingsStore, UpdateChecker/AppUpdater, LaunchAtLoginController
│       └── UI/
│           ├── Picker/          # PickerPanel/View/ViewModel, rows, previews, snippet editor
│           └── Settings/        # General/History/Apps/Shortcuts/Permissions tabs
├── assets/clipnest-icons/      # Source logo/icon SVGs (master + treatments)
├── .github/workflows/          # release.yml — auto-release on push to main (macos-26)
├── scripts/                    # install/update (curl + checksum verify), dev-cert/dev-install (local dev signing),
│                                #   build/sign/notarize/package_dmg (release build steps), release-cert (one-time
│                                #   release signing key), release-local (build + publish a release from your Mac)
└── docs/                       # architecture, features, usage, API reference + review reports
```

## Release

Releases are **automated** via GitHub Actions ([`release.yml`](.github/workflows/release.yml)). To ship a version: bump `MARKETING_VERSION` in `ClipnestApp/project.yml` and push to `main`. The workflow reads the version and, if no matching `v<version>` tag exists yet, builds Clipnest, publishes a GitHub [Release](../../releases) with a `.dmg` and a `.dmg.sha256` checksum, and creates the tag on that commit. No manual `git tag` needed. (`scripts/release-local.sh` does the same thing from your own machine, for when GitHub Actions minutes aren't available — see its header comment for the full guarantee list.)

> The release job runs on the **`macos-26`** runner (Xcode 26) — required, because on Xcode 16.x SwiftData crashes under `swift test` with `Unable to determine Bundle Name` in a hostless package test target.

**Signing, honestly:** Clipnest is not distributed through the Mac App Store or a notarized, Developer-ID-signed `.dmg` by default. The supported install path (`scripts/install.sh` / `scripts/update.sh`) downloads with `curl`, which never sets the `com.apple.quarantine` flag — that flag, not the code signature, is what triggers Gatekeeper's "unidentified developer" check and its notarization gate, so a browser-downloaded copy would need it and a `curl`-installed one doesn't. In place of Gatekeeper, those scripts verify the `.dmg` against a SHA-256 checksum published alongside every release, and refuse to install anything unverifiable.

Every release is still signed — with one long-lived, self-signed certificate (`scripts/release-cert.sh`, run once ever), not a throwaway ad-hoc identity. That matters because macOS ties an Accessibility grant to the app's designated code requirement: an ad-hoc build gets a new one every build and would invalidate every user's grant on each update, while signing every release with the same certificate keeps the requirement — and the grant — stable across updates. This is **not** a Developer ID and does **not** enable notarization on its own; if you set real Apple Developer ID + notary secrets in the repo (see the workflow header for the exact names), `release.yml` signs and notarizes with those instead for a fully Gatekeeper-clean `.dmg`. Without them, `release.yml` ships an unsigned `.dmg`; `scripts/release-local.sh` always signs with the stable self-signed certificate.

Under the hood both release paths chain the same shell scripts in [`scripts/`](scripts/):

```bash
scripts/release-cert.sh          # once, ever: mints the stable self-signed release certificate
scripts/build.sh                 # xcodegen generate → xcodebuild archive → exports Clipnest.app to build/
scripts/sign.sh   "<identity>"   # codesign --sign "<identity>" build/Clipnest.app
scripts/notarize.sh "<profile>"  # optional, Developer ID only: zips, submits to notarytool --wait, staples the ticket
scripts/package_dmg.sh           # wraps create-dmg (or an hdiutil fallback) → build/Clipnest.dmg
```

`build.sh` never needs a signing identity — it always produces a runnable `build/Clipnest.app` on its own, so it's safe to run at any time. `sign.sh` takes a codesign identity as its first argument or `$CODESIGN_IDENTITY` — never hardcoded — whether that's the self-signed release certificate or your own real Developer ID (find installed identities with `security find-identity -v -p codesigning`). `notarize.sh` only works with a genuine Developer ID identity (Apple's notary service rejects self-signed submissions) and takes an `xcrun notarytool` keychain profile name as its first argument or `$NOTARY_PROFILE`.

None of this requires an Apple Developer account to build, run, or even distribute Clipnest via the supported curl-based install path — an account is only needed if you want the *optional* Gatekeeper-clean, notarized `.dmg` instead.

## Roadmap

- [x] Reusable snippets + keyword expansion in any app
- [x] Paste without formatting
- [x] Hover previews for images, long text, and files
- [x] Settings window: pause capture, clear-all history, custom hotkey rebinding, launch-at-login, excluded apps
- [x] Configurable retention (keep N days / N items)
- [x] Background check for new releases
- [ ] Fully automatic, in-app updates (today: a background check nudges you, but installing still runs `scripts/update.sh` in Terminal — see [Update](#update))
- [ ] Notarized, Gatekeeper-clean `.dmg` by default (works today via the curl install path + a stable self-signed certificate; real Developer ID signing/notarization are opt-in for maintainers — see [Release](#release))
- [ ] macOS Shortcuts (App Intents) actions

## Contributing

Issues, ideas, and pull requests are welcome. Clipnest is a small, readable codebase built to be hacked on — clone it, run `swift test`, and dive in. The core logic has no Xcode dependency, so most contributions can be developed and tested from the command line.

## License

Clipnest is released under the [MIT License](LICENSE) — free to use, modify, and share.

---

<div align="center">
<sub><strong>Clipnest</strong> · a free, open-source, native clipboard history manager for macOS · clipboard manager · copy-paste history · snippets & text expansion · Mac productivity</sub>
</div>
