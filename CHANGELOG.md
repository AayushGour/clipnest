# Changelog

All notable changes to Clipnest are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/) — with the
caveat that, per the SemVer spec itself, everything in the `0.x` series below
was initial development, where the public API/behavior could and did change
at any time.

## [Unreleased]

## [1.6.0] - 2026-10-21

### Added

- Welcome window: granting permissions is now required — Continue unlocks only
  once Accessibility (macOS) or keyboard access and the GNOME extension (Linux)
  are set up; a low-key "Set up later" first confirms what won't work. Linux
  ends with a "Log out to finish setup" step (Log Out Now / Later) when a
  re-login is pending. Settings → Permissions no longer claims the macOS hotkey
  needs Accessibility.
- Snippets: the editor explains that the Tag is the expansion keyword (type it
  in any app, select it, press the expand shortcut — shows your current
  binding) and refuses a tag another snippet already uses, naming that snippet.
  Tags match ignoring case and surrounding spaces.
- Snippet expansion says why it couldn't expand instead of beeping: nothing
  selected, no snippet with that tag, Accessibility off (macOS), or the app
  didn't accept the replacement. macOS shows a small message near the pointer
  that never takes focus and is hidden from screen sharing; Linux posts a
  desktop notification.
- Paused capture is visible: the macOS menu-bar icon dims and gains a pause
  mark (VoiceOver: "Clipnest — capture paused"); the Linux tray switches to a
  paused icon with a "Capture paused" tooltip, also when paused from Settings.

### Changed

- Default history limit raised from 1,000 to 2,500 items. If you never changed
  the limit you get the new default automatically; a limit you chose is kept.

## [1.5.0] - 2026-10-20

### Accessibility

- macOS VoiceOver: every picker row (History, Pinned, Snippets) is now a single
  labelled element ("Text, pinned, 2 minutes ago: ...", "Image, 1200 by 800, 5
  minutes ago", "Snippet Sig, keyword sig: ...") with button/selected traits,
  paste as its default action, and Pin/Unpin, Delete, Save as Snippet, Paste as
  plain text, Copy Recognized Text and Edit as custom actions. Tabs and type
  filters expose full names ("Images filter") and the selected trait; arrow-key
  highlight changes are announced. Linux (Orca): rows, tabs, filter chips and
  row buttons get accessible labels, filter changes are announced.

### Added

- Welcome window: new "Open Clipnest at login" step (pre-checked, shared with
  Settings → General) so clipboard history keeps recording after a reboot.
- "Check for Updates…" in the macOS menu-bar menu and the Linux tray menu: runs
  an immediate check (even with automatic checking off) and reports "You're up
  to date (x.y.z)" or offers the update.
- Linux: package install prints a notice that the GNOME Shell extension is set
  up automatically on first launch and needs one log out/in to activate the
  hotkey.
- CI: macOS `swift test` and Mac app `xcodebuild test` run on every pull
  request; releases are gated on the same suite; workflows use concurrency
  groups and SHA-pinned actions.
- Picker shortcuts: `⌘]` / `⌘[` (Linux `Ctrl+]` / `Ctrl+[`) cycle the type
  filter; `⌘E` edits the highlighted snippet (Linux already had `Ctrl+Shift+E`);
  `⌘Y` / `Ctrl+Y` shows or hides the preview of the highlighted item even when
  "show preview on keyboard selection" is off. The active type filter now shows
  its name next to the icons (macOS chip stays expanded; Linux label).

### Changed

- Footer hints: macOS drops "↑↓ move" and gains "⌘[/] filter" / "⌘E edit"; the
  Linux footer's "Ctrl+Shift+E replace" is corrected to "edit" (it always edited
  the snippet) and gains filter/preview hints.

### Fixed

- Pressing Backspace with an empty picker search no longer permanently deletes
  the highlighted clip. Deleting needs `⌘⌫` on macOS and `Ctrl+Delete` on Linux
  (bare Delete/Backspace never delete).
- The New/Edit Snippet window now activates Clipnest and takes keyboard focus
  when another app is frontmost (typing and Esc used to go to the other app).
- Welcome window: the Accessibility step now says the hotkey works without it;
  the permission is only needed to paste directly and expand snippets.

### Security

- Linux OCR refuses PNGs over 40 megapixels and caps decompression at the size
  the PNG header declares, so a tiny crafted clipboard image can no longer
  exhaust memory.
- Linux in-app updater: the root helper refuses a .deb that is not strictly
  newer than the installed version (downgrade/replay protection).
- macOS: picker, item preview and snippet editor windows are hidden from screen sharing and
  recording (`sharingType = .none`; best effort — macOS 15+ ScreenCaptureKit may
  still capture them in some modes).
- macOS updater hardening: the in-app updater no longer pipes `scripts/update.sh`
  from the mutable `main` branch into `bash`. It fetches the script from the
  release tag being installed and pins the version (`CLIPNEST_VERSION`, the
  tag strictly validated as `vN.N.N` before it reaches any URL or command).
  `update.sh` and the macOS path of `install.sh` now copy the new app next to
  the old one, verify its version and code signature (and, when an app is
  installed, that it is signed by the same identity), then swap it in with a
  rollback if anything fails, instead of deleting the old app first.
  `hdiutil attach` no longer skips image verification (`-noverify` removed), and
  every curl is restricted to https with TLS 1.2+.
- Linux: the in-app "Install Update" no longer hands a user-owned `/tmp` file
  path to `pkexec apt-get install` (a check-then-use race: any same-user
  process could swap the .deb while the authentication dialog was open). The
  .deb is now streamed to a new root helper, `clipnest-install-update`
  (polkit action `app.clipnest.install-update`), which copies it into a
  root-only directory, re-verifies its SHA-256 and `Package: clipnest`, and only
  then runs `apt-get install`. Update downloads are also restricted to https
  (including redirects).

## [1.4.0] - 2026-10-19

### Added

- macOS: a one-time Welcome window on first launch, and once for existing users
  after updating. Two steps: an optional Accessibility grant that now happens here instead of
  as a surprise system dialog at launch, then *Try your hotkey* (your live
  hotkey, a shortcut to Settings → Shortcuts, and a check that confirms the
  hotkey opens the picker). Fully keyboard and VoiceOver accessible; closes with Esc or
  ⌘W and never reappears on its own. Reopen it from the menu bar via
  *Getting Started…*. The platform-neutral gate, step model and copy live in
  `ClipnestViewModels` and are shared with Linux.
- Linux: the same two-step Welcome window (GTK 4), shown on first launch and
  once for existing users after updating. Step 1 combines *Keyboard access*
  (the `clipnest-input` grant, with a *Try Again* button on failure) and the
  GNOME extension status (*Turn On* / *Try Again* / "Log out once to finish
  setup"). It replaces the old one-off "Set Up Auto-Paste?" dialog (removed;
  its text now lives in one shared place used by Settings → Permissions too).
  Step 2 is *Try your hotkey*. Non-modal, Esc or Ctrl+W closes it, Return activates Continue/Done. Reopen
  it from the tray menu via *Getting Started…*.
- Linux: Clipnest now installs its GNOME Shell extension for your user on first
  launch and enables it, refreshing it on later launches when an update ships a
  newer version (GNOME 42-44 and 45+ both supported). Log out and back in once
  to finish setup. It never installs on non-GNOME desktops, never re-enables an
  extension you turned off, and respects GNOME's "disable user extensions"
  switch. `scripts/uninstall.sh` now removes it too.

### Security

- Clipboard history and snippets are no longer readable by other local user
  accounts. On macOS the data folder (`~/Library/Application Support/Clipnest`)
  was world-listable (0755) and the history/snippet database files were
  world-readable (0644). The folder is now owner-only (0700) and the database
  files (including `-wal`/`-shm`) owner-only (0600); existing installs are
  corrected on the next launch. Linux already used an owner-only data folder;
  its database files are now also tightened to 0600. Copied images and other
  large clips (the `blobs/` folder) are now written owner-only (0600) too, and
  existing blob files from earlier versions are tightened once, in the
  background, shortly after launch (retried on the next launch if it can't
  finish; never delays startup).

### Fixed

- macOS: if Clipnest can't open its history database at launch, it now shows an
  alert instead of silently quitting (the menu-bar icon just vanishing). The
  alert offers **Reset History…** (after a confirmation, sets aside both the
  clipboard history and snippets stores into a timestamped backup folder in
  `~/Library/Application Support/Clipnest` — nothing is deleted — and retries),
  **Show in Finder**, or **Quit**.

## [1.3.0] - 2026-10-14

### Added

- The picker now has a visible close (x) button at the right of its header
  (macOS: the same hover-expanding icon button as the type chips, revealing
  "Close (esc)"; Linux: tooltip "Close (esc)"). Previously Esc was the only way
  to close it, and nothing said so.

## [1.2.1] - 2026-10-10

### Fixed

- macOS: only one copy of Clipnest runs at a time. A second copy (for
  example a build output launched while the installed app runs) now quits on
  launch instead of also registering ⌥⌘V/⌥⌘E, which made pasting work or
  fail depending on which copy got the key.
- macOS: snippet expansion (⌥⌘E) without Accessibility now beeps straight
  away and logs that Accessibility is missing, instead of trying a copy/paste
  macOS silently drops and logging a misleading `copy phase FAILED`.
- macOS: a picker paste that can only copy because Accessibility is missing
  now logs why, instead of failing silently.
- macOS: Clipnest's synthesized ⌘C/⌘V now also carries the left-Command
  device flag that a real key press sets, as other clipboard managers do, for
  apps that check it.

## [1.2.0] - 2026-10-10

### Added

- Linux: the picker footer now shows the installed version (`v1.2.0`) at its
  right edge, with an accent dot when a newer release is available. Clicking
  it opens Settings, where "Check for Updates Now" / "Install Update…" live.

### Fixed

- Linux: the footer's shortcut hints now wrap onto a second line when needed; a
  long hint string no longer widens the picker beyond its 560 px width.

## [1.1.0] - 2026-10-10

### Added

- One install command for macOS and Linux:
  `curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash`
  now detects the OS (and, on Linux, the CPU architecture), fetches the latest
  release and installs it. On Linux it checks for Ubuntu 22.04/24.04 with GNOME
  (override with `CLIPNEST_FORCE=1`), verifies the tarball against the SHA-256
  digest GitHub publishes for the release asset (fail closed) and the bundled
  `SHA256SUMS`, then runs the bundled installer. `CLIPNEST_DRY_RUN=1` does
  everything except the install. See [README](README.md#install).
- `scripts/uninstall.sh`: one uninstall command for macOS and Linux
  (`curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/uninstall.sh | bash`).
  Removes the app and keeps your history, snippets and settings; `--purge` (or
  `CLIPNEST_PURGE=1`) also deletes them (and, on Linux, runs `apt-get purge`,
  the per-user GNOME Shell extension and autostart entry). `CLIPNEST_DRY_RUN=1`
  prints the actions without doing them. See [README](README.md#uninstall).
- New setting, **Settings -> General -> "Show preview when selecting with the
  keyboard"** (off by default): when on, moving through the picker list with the
  arrow keys also shows the item preview beside the highlighted row, not only
  when hovering with the pointer. Hovering a row still takes priority.
- Linux: the hover preview now also works on the Snippets tab (it shows the
  snippet's body), and the keyboard-selection preview setting is honoured by the
  GTK picker, anchored beside the selected row.
- Linux: a copy that does not reach history now leaves a log line saying why
  (the owner's offered targets, a refused or timed-out conversion, a privacy or
  pause rejection). Previously every such drop was silent. The lines carry
  metadata only (type names, never content, and no source id on privacy
  rejections). See [docs/features.md](docs/features.md#1-clipboard-capture).
- A top-level `Makefile` wrapping the test, lint, build, `.deb`, install and
  dev flows (`make` lists the targets; see the README's "Make targets").

### Changed

- `scripts/install.sh` now runs everything inside a `main` function (a truncated
  `curl | bash` download cannot run a partial script), and every `curl` is
  restricted to HTTPS with TLS 1.2 or newer. The macOS install behaviour is
  unchanged.

### Fixed

- Pressing Enter twice quickly (or double-clicking) on a picker row now pastes
  once. The guard against a second paste while one is being written and
  confirmed applies on both platforms; on Linux the picker stays visible during
  that wait, so it was reachable.
- Linux: the hover preview no longer visibly jumps (for example from the left of
  the picker to the right) when it appears or changes. It is placed once at its
  final position and all previews share one width.
- Linux: a very long or multi-line copy no longer makes its picker row tall. Rows
  show at most 3 lines (ellipsized), the picker window is a little taller, and
  the hover preview is height-bounded and scrolls inside itself.
- Linux (Wayland): the hover preview appeared nowhere on GNOME Wayland since the
  side-by-side placement change: the compositor dismissed a preview that did not
  overlap the picker window. It now overlaps the window edge by a couple of
  pixels and shows, level with the hovered row.
- Linux: moving through the picker list with the arrow keys now scrolls the list
  so the selected row always stays in view (it used to move off-screen).
- Linux (Wayland): pressing Enter on a picker row pasted the previously copied
  clipboard instead of the selected item. The picker was hidden before the
  clipboard write, and GNOME's compositor ignores a clipboard write from a
  window that has lost keyboard focus. The write now happens first, is
  confirmed, and only then is the picker hidden. macOS behaviour is unchanged.
- Linux: the hover preview now opens beside the picker window, level with the
  hovered row (on whichever side has room), as on macOS, instead of at the
  mouse cursor.
- Linux: a clipboard owner that answered a text request with zero bytes was
  saved as a blank history row. It is now treated as "nothing to capture".
- Linux: a text copy whose preferred text type comes back empty, refused or
  undecodable now falls back to the owner's other advertised text types,
  instead of being dropped.

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

[Unreleased]: https://github.com/AayushGour/clipnest/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/AayushGour/clipnest/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/AayushGour/clipnest/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/AayushGour/clipnest/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/AayushGour/clipnest/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/AayushGour/clipnest/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/AayushGour/clipnest/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/AayushGour/clipnest/compare/v1.0.0...v1.1.0
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
