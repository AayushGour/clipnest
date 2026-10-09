# Changelog

All notable changes to Clipnest are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/) — with the
caveat that, per the SemVer spec itself, everything in the `0.x` series below
was initial development, where the public API/behavior could and did change
at any time.

## [Unreleased]

### Fixed

- Linux: a clipboard owner that answered a text request with zero bytes was
  saved as a blank history row. It is now treated as "nothing to capture".

### Added

- Linux: a copy that does not reach history now leaves a log line saying why
  (the owner's offered targets, a refused or timed-out conversion, a privacy or
  pause rejection). Previously every such drop was silent. See
  [docs/features.md](docs/features.md#1-clipboard-capture).

## [1.0.0] - 2026-10-06

The Linux port graduates from "builds and runs" to verified on real hardware.
Every fix below was reproduced on physical Ubuntu 24.04 (GNOME 46, Wayland)
before being fixed, and confirmed fixed there afterwards.

### Fixed

- Linux: picking an item from the picker could freeze Clipnest ("not
  responding") when auto-paste wasn't set up. The app's own clipboard write
  is now recognized reliably, instead of the picker thread waiting on a
  clipboard read that could never be served.
- Linux: a copy made by a password manager (e.g. KeePassXC's "clear
  clipboard after N seconds") was being saved into history once the
  password manager let go of the clipboard and GNOME re-published it. Such
  copies are now recognized as concealed and skipped, the same way the
  original copy already was.
- Linux: the picker no longer stays open behind a window that just took
  focus — the next hotkey press opens it again instead of closing it.
- Linux: choosing a history item while a terminal window is focused now
  pastes it (Ctrl+Shift+V), instead of typing a literal `^V` into the
  terminal.
- The in-app update check (and `scripts/update.sh` on macOS) no longer
  offers to "update" to a release older than the one already installed —
  only a strictly newer version counts, and a non-numeric version now
  fails closed instead of being treated as newer.

### Added

- Linux: the tray menu gained a "Pause Capture" item, matching the pause
  toggle that's long been in the macOS menu bar.

### Internal

- Fixed a lint failure and a packaging-script path bug that were blocking
  the release workflows for this version, and a CI bug that would have
  attached the previous version's Linux build artifacts to this release.
- The Linux release workflow now runs its build steps under bash. Under
  the container's default `sh` it failed on `set -o pipefail`, so the
  1.0.0 Linux packages were missing from the release when it was first
  published.
- Refreshed README, architecture/features/API docs, and test guides for
  the finished Linux port.
- Updated SEO/AEO metadata to distinguish this project from unrelated
  products also called "ClipNest" (other Mac/Microsoft Store apps and
  GitHub repos).

## [0.9.4] - 2026-09-21

Linux only — an internal packaging version bump, built as tarballs and
never published as a GitHub release. No tag exists for it; see commit
[`a071827`](https://github.com/AayushGour/clipnest/commit/a07182712457991e6437847812239e77e1c9ab89).

### Fixed

- Linux: startup no longer blocks the GTK main thread. Connecting to IBus
  and cleaning up a leftover crash-safety marker from a previous
  force-quit used to run inline before the window could appear; both now
  run in the background, which was most noticeable as a stall right after
  a force-quit.
- Linux: Settings → Permissions no longer shows the same status message
  twice (once in normal text, once again greyed out beneath it).

### Internal

- Linux: per-call D-Bus timeouts are now actually enforced — a call asking
  for a short timeout could previously still block for as long as the
  connection's original, larger timeout (measured: a 100 ms request taking
  up to 3017 ms, now 108 ms). Not user-visible on its own.
- Note from the original packaging notes: this release did not fix the
  reported freeze when picking an item from the picker — that was
  unreproduced at the time, and was fixed later in 1.0.0.

## [0.9.3] - 2026-09-14

Linux only — an internal packaging version bump, built as tarballs and
never published as a GitHub release. No tag exists for it; see commit
[`0e68a56`](https://github.com/AayushGour/clipnest/commit/0e68a569bb68ff1e1aa210ddc57abfa4bc54120d).
This is the initial Linux port: everything below landed in this one
version.

### Added

- Linux: first working build of Clipnest for Ubuntu with GNOME — clipboard
  history, instant search, pinning, snippets, and a global hotkey, on a
  native GTK 4 interface styled to approximate the macOS picker.
- Linux: on-device OCR for copied images, loaded via `dlopen` so it's not
  a hard dependency of the base package.
- Linux: paste support for images, files, and rich text; row action
  buttons, a context menu, and a snippet editor; launch-at-login, an
  OCR backfill action, and "Clear All History".
- Linux: snippet-keyword expansion in other apps. The first working path
  used AT-SPI; it was later reworked to go through IBus directly so
  expansion also works reliably on GNOME Wayland while a modifier key is
  still held down.
- Linux: system tray icon and menu, a Permissions tab, working CLI flags,
  and a GNOME Shell extension that delivers the global hotkey on Wayland.
- Debian packaging for three packages (`clipnest`, `clipnest-ocr`,
  `clipnest-ocr-data`) and Linux CI.
- An in-app updater for the Linux build.

### Fixed

- Linux: a large number of stabilization fixes found through real-hardware
  and VM testing, including: background services (D-Bus control path)
  being killed unexpectedly, D-Bus array marshalling that broke the tray
  menu, a GSettings schema lookup crash, the window's `WM_CLASS` not being
  set before GTK initialized, the picker fighting its own context menu and
  snippet editor for focus, snippet captures being attributed to the wrong
  app, and a P0 data-loss bug where pressing Delete while the search box
  was focused could destroy the wrong clip item.
- Linux: the GNOME Shell extension's hotkey path now works end to end on a
  real GNOME Shell, including on GNOME 45+ (its ESM variant previously
  never loaded there).

### Changed

- Investigated several approaches to fixing snippet expansion on GNOME
  Wayland (synthesizing copy/paste while releasing held modifier keys,
  then per-input-device modifier tracking); neither held up under
  measurement and both were abandoned in favor of the IBus-based fix
  above, which does not depend on synthesized keystrokes at all.

## [0.9.2] - 2026-09-12

### Fixed

- macOS: snippet expansion (⌥⌘E) could silently do nothing in several
  apps, reported against WhatsApp and Claude desktop and reproduced in
  Safari, Brave, VS Code, and Antigravity. The underlying cause: a
  successful-looking Accessibility API response doesn't guarantee a text
  selection was actually read correctly or that a replacement actually
  took effect. Clipnest now verifies both instead of trusting the API's
  success code, falling back to its clipboard-based replacement when it
  can't confirm the direct path worked. TextEdit keeps the faster direct
  path, since it's the one app where that signal was found to be honest.

## [0.9.1] - 2026-09-07

### Fixed

- Eliminated an app-launch stall and hangs when clipboard history contains
  images — ten related defects traced to store construction blocking
  launch, unbounded thumbnail decoding, and image caches with no byte or
  count limit.

### Internal

- New project website ([aayushgour.github.io/clipnest](https://aayushgour.github.io/clipnest/)),
  later redesigned with real screenshots, copy-to-clipboard snippets, and
  SEO/AEO metadata.

## [0.9.0] - 2026-09-04

### Added

- On-device OCR for copied images (via Apple's Vision framework), off by
  default, with a Fast/Accurate quality setting in Settings → History.
  Recognized text folds into the existing search index, so screenshots
  become searchable without a separate search mode, and a Settings button
  can run OCR over images already in history.
- ⌥Return on an image row with recognized text now pastes that text
  instead of the image.
- ⌘, now opens Settings from the picker as well as from the Settings
  window (intentionally not a global hotkey).

### Fixed

- P0: pasting could hang indefinitely (reproduced hanging for over two
  minutes). OCR's image processing was pinning every available background
  thread, so a paste could never get scheduled; it now runs on its own
  dedicated queue.
- The Settings window could open behind other apps, because macOS 26
  won't bring a window to the front for an app with no Dock icon; opening
  Settings now briefly shows a Dock icon and hides it again on close.
- A race between Clipnest's own self-paste suppression and its capture
  poll could insert duplicate history rows and waste storage.
- ⌘S no longer opens the "save as snippet" form on image, rich-text, or
  file rows, since only text and link items have a plain-text body to
  seed a snippet from. The picker's hint bar no longer truncates its text.

## [0.8.1] - 2026-08-21

### Internal

- Added a local release script (`scripts/release-local.sh`) for building
  and publishing a Clipnest release from a developer machine when GitHub
  Actions isn't available.

## [0.8.0] - 2026-08-19

### Added

- A background check for new releases, run automatically every 24 hours,
  with a Settings toggle to turn it off and an indicator in the app when
  an update is available.

## [0.7.2] - 2026-08-17

### Fixed

- Hover and arrow-key item previews now correctly choose which side of
  the screen to open on, instead of occasionally rendering off-screen.

## [0.7.1] - 2026-08-17

### Changed

- Reworked global hotkey delivery and accessibility-permission detection
  to be more reliable.

### Internal

- Added a release-certificate script so every release can be signed with
  the same stable identity (see the README's "Signing, honestly" section).

## [0.7.0] - 2026-08-17

### Internal

- Settings-window design docs and install instructions refactored; code
  formatting cleaned up across multiple files. No user-facing behavior
  changed in this version.

## [0.6.1] - 2026-08-14

### Fixed

- Improved error handling and output messages in the `curl`-based install
  and update scripts.

## [0.6.0] - 2026-08-14

### Added

- An in-app update indicator: the picker's footer shows the current
  version with a small dot when a newer one is available; clicking it
  runs the update for you.
- `curl`-based install and update scripts that avoid macOS's Gatekeeper
  "unidentified developer" warning without requiring a signed/notarized
  build.

### Fixed

- Clipboard blob writes no longer run on the main thread.
- The Homebrew cask's deprecated `depends_on` was fixed, and its caveats
  now document the quarantine workaround for the unsigned app.

## [0.5.0] - 2026-08-13

The first version to be tagged and published as a GitHub release.

### Internal

- Fixed an Xcode 16.2 crash ("Unable to determine Bundle Name") in
  SwiftData-backed tests by giving test containers a temp-file store and
  an explicit schema.
- Set up the GitHub Actions release workflow.

## Initial development - 2026-08-12 – 2026-08-13

Versions 0.1.0 through 0.4.0 were same-day internal version bumps made
while standing up the release pipeline, before Clipnest's first published
release (0.5.0, above). None of them were ever installed by a user.

### Added

- Initial build of the Clipnest macOS app: automatic clipboard history
  capture, the picker (search, type filters, pin, delete), a Settings
  window, and snippet keyword expansion.
- MIT license; GitHub Actions release workflow and Homebrew cask.

### Fixed

- `Sendable` conformance for `NSPasteboard` access, required by Swift 6.

[Unreleased]: https://github.com/AayushGour/clipnest/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/AayushGour/clipnest/compare/v0.9.2...v1.0.0
[0.9.4]: https://github.com/AayushGour/clipnest/commit/a07182712457991e6437847812239e77e1c9ab89
[0.9.3]: https://github.com/AayushGour/clipnest/commit/0e68a569bb68ff1e1aa210ddc57abfa4bc54120d
[0.9.2]: https://github.com/AayushGour/clipnest/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/AayushGour/clipnest/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/AayushGour/clipnest/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/AayushGour/clipnest/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/AayushGour/clipnest/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/AayushGour/clipnest/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/AayushGour/clipnest/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/AayushGour/clipnest/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/AayushGour/clipnest/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/AayushGour/clipnest/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/AayushGour/clipnest/releases/tag/v0.5.0
