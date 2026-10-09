---
layout: article
title: Features — Clipnest Clipboard Manager
description: Full clipboard history, instant search, pinning, reusable snippets with keyword expansion, optional on-device OCR, and a global hotkey — native on macOS and Linux (Ubuntu with GNOME).
permalink: /features/
---

# Features

Clipnest is a free, open-source, native menu-bar app for macOS and, since 1.0, Linux (Ubuntu 22.04/24.04 with GNOME, X11 or Wayland). It quietly remembers everything you copy — text, links, images, and files — and hands it back the instant you need it. Here's everything it does.
{: .lead}

<div class="notice" markdown="1">

**On Linux**, everything below works the same unless noted, with Linux keys: **Ctrl** takes the place of ⌘, **Alt** the place of ⌥, and **Delete** removes an item. The global hotkeys are **Alt+Super+V** (picker) and **Alt+Super+E** (expand a snippet). Platform differences are listed under [Linux differences](#linux-differences).

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<rect x="4" y="4" width="16" height="16" rx="3"></rect>
<line x1="8" y1="9" x2="16" y2="9"></line>
<line x1="8" y1="13" x2="16" y2="13"></line>
<line x1="8" y1="17" x2="13" y2="17"></line>
</svg>
</div>

## Clipboard history

</div>

- **Full clipboard history** — automatically captures everything you copy: plain text, rich text, URLs, images, and files.
- **Smart de-duplication** — copy the same thing twice and it won't clutter your history.
- **Accessibility permission survives updates (Mac)** — update Clipnest and you don't have to re-grant Accessibility: your permission survives, because every release is signed with the same certificate. See [Signing, honestly]({{ '/download/#signing-honestly' | relative_url }}) for how.
{: .detail-list}

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<circle cx="10.5" cy="10.5" r="6.5"></circle>
<line x1="15.3" y1="15.3" x2="20" y2="20"></line>
</svg>
</div>

## Finding things fast

</div>

- **Global hotkey** — press **⌥⌘V** anywhere to pop the picker open right at your cursor, over any app (even full-screen).
- **Instant search** — start typing to filter your entire copy-paste history in real time, with matches highlighted (**⌘F** to jump back to the search field).
- **Type filters** — narrow the list to just text, images, files, or links with one click.
- **Tabs** — **History**, **Pinned**, and **Snippets**, switchable with **⌘1** / **⌘2** / **⌘3**.
- **Hover previews** — hover an item (or, with **Settings -> General -> Show preview when selecting with the keyboard** on, arrow to it) and a popover shows the full content: the image at up to 40% of screen width (with any recognized text shown below it), the full scrollable text (loaded in chunks for huge clips), or a file's name, size, and path.
{: .detail-list}

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M12 4V15"></path>
<path d="M7.5 10.5L12 15L16.5 10.5"></path>
<path d="M5 19H19"></path>
</svg>
</div>

## Pasting

</div>

- **Paste into your active app** — pick an item and, with Accessibility granted, Clipnest types it straight into the field you were using; otherwise it's placed on your clipboard to paste yourself.
- **Paste without formatting** — **⌥Return** only differs from plain **Return** where there's actually something to strip: on **rich text** items it pastes the plain-text form instead of the formatted one, and on an **image row with recognized text** (see OCR below) it pastes that recognized text instead of the image. On plain text, links, files, and images with no recognized text, ⌥Return pastes exactly what Return does.
- **Pin your favorites** — keep the items you reuse most pinned to the top, always a keystroke away (**⌘P**).
{: .detail-list}

<div class="shot-frame" markdown="1">

![Clipnest's Pinned tab, showing pinned clipboard items kept at the top]({{ "/assets/screenshot-pinned.png" | relative_url }})

</div>

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M11 3H5C3.9 3 3 3.9 3 5V11C3 11.5 3.2 12 3.6 12.4L11.6 20.4C12.4 21.2 13.6 21.2 14.4 20.4L20.4 14.4C21.2 13.6 21.2 12.4 20.4 11.6L12.4 3.6C12 3.2 11.5 3 11 3Z"></path>
<circle cx="7.5" cy="7.5" r="1.5"></circle>
</svg>
</div>

## Snippets & keyword expansion

</div>

Save reusable text (a signature, boilerplate, a command) with a **Tag**, and paste it from the Snippets tab or expand it by keyword in any app — replaces your text expander too. Turn a text or link history item into a snippet with **⌘S**.

**Expand anywhere:** type a snippet's Tag in *any* app, select it, and press **⌥⌘E** — Clipnest replaces the selection with the snippet's Body. It works in every application, using a two-tier approach on the Mac: Accessibility first (reads and replaces the selection directly, without ever touching your clipboard), with a clipboard-based fallback (snapshotting and restoring your clipboard) for apps where the Accessibility API can't read the selection, such as Electron/Chrome-based apps. On Linux, expansion works on both X11 and Wayland (on Wayland it goes through IBus), and in terminals it declines rather than risk corrupting the command line.

<div class="shot-frame" markdown="1">

![Clipnest's Snippets tab, showing a saved snippet ready to expand by keyword]({{ "/assets/screenshot-snippets.png" | relative_url }})

</div>

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M2 12C2 12 5.5 5 12 5C18.5 5 22 12 22 12C22 12 18.5 19 12 19C5.5 19 2 12 2 12Z"></path>
<circle cx="12" cy="12" r="3"></circle>
</svg>
</div>

## On-device OCR (optional, off by default)

</div>

Let Clipnest read the text in your screenshots so you can find them by what they say, not just when you copied them. Turned on in Settings → History, **"Recognize text in copied images"** is **off by default**, with a **Fast** / **Accurate** quality choice — **Accurate is the default**. It runs entirely on-device — Apple's Vision framework on the Mac; on Linux, a bundled ONNX Runtime with PP-OCRv5 models shipped in the `clipnest-ocr` packages: no upload, no model download, no network call of any kind. See [Privacy]({{ '/privacy/' | relative_url }}) for the trade-off before you turn it on.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<circle cx="12" cy="12" r="3"></circle>
<path d="M12 3V5.5"></path>
<path d="M12 18.5V21"></path>
<path d="M4.93 4.93L6.7 6.7"></path>
<path d="M17.3 17.3L19.07 19.07"></path>
<path d="M3 12H5.5"></path>
<path d="M18.5 12H21"></path>
<path d="M4.93 19.07L6.7 17.3"></path>
<path d="M17.3 6.7L19.07 4.93"></path>
</svg>
</div>

## Settings

</div>

Everything about how Clipnest behaves lives in one Settings window (**⌘,**), across five tabs:

- **General** — launch Clipnest at login, pause clipboard capture with one toggle, and turn the background update check on/off.
- **History** — controls how much history is kept. The default is the most recent **1,000** items; switch to a day-based cap (30 days by default) or *Everything* (no cap at all) instead. Pinned items are always kept regardless of the cap. **Clear All History…** wipes everything (including pinned items) after a confirmation. This tab also has the OCR toggle described above.
- **Apps** — exclude specific apps from capture, on top of the built-in password-manager denylist (which can't be removed).
- **Shortcuts** — rebind *both* global hotkeys (open the picker, expand a snippet) to whatever key combination you want.
- **Permissions** — on the Mac, see whether Accessibility is granted and fix it in one click, including guidance for the one case System Settings can't diagnose on its own (a rebuilt/updated app whose old permission entry no longer matches). On Linux, see your setup status and grant the one-time auto-paste permission.
{: .detail-list}

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<rect x="3" y="6" width="18" height="12" rx="2"></rect>
<line x1="6" y1="9.5" x2="6" y2="9.5"></line>
<line x1="9.5" y1="9.5" x2="9.5" y2="9.5"></line>
<line x1="13" y1="9.5" x2="13" y2="9.5"></line>
<line x1="16.5" y1="9.5" x2="16.5" y2="9.5"></line>
<line x1="6" y1="13" x2="6" y2="13"></line>
<line x1="9.5" y1="13" x2="9.5" y2="13"></line>
<line x1="13" y1="13" x2="13" y2="13"></line>
<line x1="16.5" y1="13" x2="16.5" y2="13"></line>
<line x1="7.5" y1="15.7" x2="15.5" y2="15.7"></line>
</svg>
</div>

## Keyboard-first

</div>

Arrows to move, Return to paste, Esc to dismiss, ⌘F to search, ⌘P to pin, ⌘⌫ to delete, ⌘1/2/3 for tabs, ⌘, for Settings. Both global hotkeys (⌥⌘V and ⌥⌘E) are rebindable — see [Usage]({{ '/usage/' | relative_url }}) for the full shortcut reference.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M13 3L6 13H11L10 21L18 11H12L13 3Z"></path>
</svg>
</div>

## Featherweight & native

</div>

Pure Swift, sips almost no memory. On the Mac it's SwiftUI, a few MB, feels like part of macOS, and lives in the menu bar with no Dock icon day-to-day (opening Settings briefly shows one). On Linux it's a native GTK 4 app with a tray icon (Open Clipnest, Pause Capture, Settings…, Quit).

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

<div class="panel-icon" aria-hidden="true">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
<path d="M12 3L19 6V11C19 16 16 19.5 12 21C8 19.5 5 16 5 11V6L12 3Z"></path>
<path d="M9 12L11 14L15.5 9.5"></path>
</svg>
</div>

## Private by design

</div>

Everything stays on your computer — no servers, no sync, no telemetry, no account. See [Privacy]({{ '/privacy/' | relative_url }}) for the full picture, including the OCR trade-off.

</div>

<div class="content-panel" markdown="1">

<div class="content-panel-head" markdown="1">

## Linux differences

</div>

- **Picker position.** GNOME doesn't let apps place their own windows on Wayland, so the picker opens where GNOME puts it rather than at your cursor. The optional GNOME Shell extension restores cursor placement and showing above full-screen windows — see [Download]({{ '/download/#linux' | relative_url }}).
- **Auto-paste permission.** Auto-paste needs a one-time grant that adds you to a dedicated `clipnest-input` group, which can create a virtual keyboard and nothing else. Until then Clipnest copies your choice and you press Ctrl+V yourself.
- **Terminals.** Pasting into GNOME Terminal and other VTE terminals uses Ctrl+Shift+V automatically.
- **Password managers.** Copies marked as secret (`x-kde-passwordManagerHint`, used by KeePassXC and others) are never stored. On Wayland, Clipnest can't tell which app made a copy, so Settings → Apps exclusions apply only to X11/XWayland apps; the secret marker works everywhere.
- **Ubuntu 22.04** ships GTK 4.6, which has an upstream clipboard bug that can, rarely, make Clipnest quit. It's fixed in GTK 4.10+ (Ubuntu 24.04). Your history is never affected.
{: .detail-list}

</div>

<div class="cta-inline" markdown="1">

Ready to try it? [Download Clipnest]({{ '/download/' | relative_url }}) or read the [usage guide]({{ '/usage/' | relative_url }}) to get started.

</div>
