---
layout: default
title: Features — Clipnest Clipboard Manager
description: Full clipboard history, instant search, pinning, reusable snippets with keyword expansion, optional on-device OCR, and a global hotkey — all native to macOS.
permalink: /features/
---

# Features

Clipnest is a free, open-source, native menu-bar app for macOS. It quietly remembers everything you copy — text, links, images, and files — and hands it back the instant you need it. Here's everything it does.

## Clipboard history

- **Full clipboard history** — automatically captures everything you copy: plain text, rich text, URLs, images, and files.
- **Smart de-duplication** — copy the same thing twice and it won't clutter your history.
- **Accessibility permission survives updates** — update Clipnest and you don't have to re-grant Accessibility: your permission survives, because every release is signed with the same certificate. See [Signing, honestly]({{ '/download/#signing-honestly' | relative_url }}) for how.

## Finding things fast

- **Global hotkey** — press **⌥⌘V** anywhere to pop the picker open right at your cursor, over any app (even full-screen).
- **Instant search** — start typing to filter your entire copy-paste history in real time, with matches highlighted (**⌘F** to jump back to the search field).
- **Type filters** — narrow the list to just text, images, files, or links with one click.
- **Tabs** — **History**, **Pinned**, and **Snippets**, switchable with **⌘1** / **⌘2** / **⌘3**.
- **Hover previews** — hover (or arrow to) an item and a popover shows the full content: the image at up to 40% of screen width (with any recognized text shown below it), the full scrollable text (loaded in chunks for huge clips), or a file's name, size, and path.

## Pasting

- **Paste into your active app** — pick an item and, with Accessibility granted, Clipnest types it straight into the field you were using; otherwise it's placed on your clipboard to paste yourself.
- **Paste without formatting** — **⌥Return** only differs from plain **Return** where there's actually something to strip: on **rich text** items it pastes the plain-text form instead of the formatted one, and on an **image row with recognized text** (see OCR below) it pastes that recognized text instead of the image. On plain text, links, files, and images with no recognized text, ⌥Return pastes exactly what Return does.
- **Pin your favorites** — keep the items you reuse most pinned to the top, always a keystroke away (**⌘P**).

## Snippets & keyword expansion

Save reusable text (a signature, boilerplate, a command) with a **Tag**, and paste it from the Snippets tab or expand it by keyword in any app — replaces your text expander too. Turn a text or link history item into a snippet with **⌘S**.

**Expand anywhere:** type a snippet's Tag in *any* app, select it, and press **⌥⌘E** — Clipnest replaces the selection with the snippet's Body. It works in every application, using a two-tier approach: Accessibility first (reads and replaces the selection directly, without ever touching your clipboard), with a clipboard-based fallback (snapshotting and restoring your clipboard) for apps where the Accessibility API can't read the selection, such as Electron/Chrome-based apps.

## On-device OCR (optional, off by default)

Let Clipnest read the text in your screenshots so you can find them by what they say, not just when you copied them. Turned on in Settings → History, **"Recognize text in copied images"** is **off by default**, with a **Fast** / **Accurate** quality choice — **Accurate is the default**. It runs entirely on-device with Apple's Vision framework: no upload, no model download, no network call of any kind. See [Privacy]({{ '/privacy/' | relative_url }}) for the trade-off before you turn it on.

## Settings

Everything about how Clipnest behaves lives in one Settings window (**⌘,**), across five tabs:

- **General** — launch Clipnest at login, pause clipboard capture with one toggle, and turn the background update check on/off.
- **History** — controls how much history is kept. The default is the most recent **1,000** items; switch to a day-based cap (30 days by default) or *Everything* (no cap at all) instead. Pinned items are always kept regardless of the cap. **Clear All History…** wipes everything (including pinned items) after a confirmation. This tab also has the OCR toggle described above.
- **Apps** — exclude specific apps from capture, on top of the built-in password-manager denylist (which can't be removed).
- **Shortcuts** — rebind *both* global hotkeys (open the picker, expand a snippet) to whatever key combination you want.
- **Permissions** — see whether Accessibility is granted and fix it in one click, including guidance for the one case System Settings can't diagnose on its own (a rebuilt/updated app whose old permission entry no longer matches).

## Keyboard-first

Arrows to move, Return to paste, Esc to dismiss, ⌘F to search, ⌘P to pin, ⌘⌫ to delete, ⌘1/2/3 for tabs, ⌘, for Settings. Both global hotkeys (⌥⌘V and ⌥⌘E) are rebindable — see [Usage]({{ '/usage/' | relative_url }}) for the full shortcut reference.

## Featherweight & native

Pure Swift/SwiftUI, a few MB, sips almost no memory, feels like part of macOS. Lives in the menu bar with no Dock icon day-to-day (opening Settings briefly shows one).

## Private by design

Everything stays on your Mac — no servers, no sync, no telemetry, no account. See [Privacy]({{ '/privacy/' | relative_url }}) for the full picture, including the OCR trade-off.

---

Ready to try it? [Download Clipnest]({{ '/download/' | relative_url }}) or read the [usage guide]({{ '/usage/' | relative_url }}) to get started.
