---
layout: article
title: Getting Started with Clipnest — Usage Guide
description: Learn Clipnest's hotkeys, search, pinning, and snippet expansion — get productive with your Mac clipboard manager in minutes.
permalink: /usage/
---

# Using Clipnest

A guide for everyday use — install, permissions, clipboard history, snippets, and troubleshooting.
{: .lead}

> Looking for the developer/API reference instead? See [`docs/API.md`](https://github.com/AayushGour/clipnest/blob/main/docs/API.md) on GitHub.

<nav class="box-grid" aria-label="On this page" markdown="1">

<p class="eyebrow">On this page</p>

- [1. What is Clipnest](#1-what-is-clipnest)
- [2. Requirements](#2-requirements)
- [3. Install](#3-install)
- [4. First launch & permissions](#4-first-launch--permissions)
- [5. Clipboard history](#5-clipboard-history)
- [6. Snippets](#6-snippets)
- [7. Privacy & exclusions](#7-privacy--exclusions)
- [8. Settings window](#8-settings-window)
- [9. Keyboard shortcuts reference](#9-keyboard-shortcuts-reference)
- [10. Troubleshooting](#10-troubleshooting)
- [11. Uninstall](#11-uninstall)

</nav>

## 1. What is Clipnest

Clipnest is a small, native menu-bar app for Mac that quietly remembers everything you copy — text, links, images, and files — so you can search back through it and paste it again later. It also has **Snippets**: reusable bits of text you write yourself, which you can drop into any app by typing a short keyword.

Clipnest lives only in the menu bar (there's no Dock icon day-to-day, no window that stays open) and is entirely private: **nothing you copy or type into Clipnest ever leaves your Mac.** There's no account, no cloud sync, and no analytics — everything is stored in a local database in your user Library folder. The one narrow exception to "no network access" is an optional, once-a-day background check against GitHub's public Releases API to see whether a newer version exists (on by default, and it never downloads or installs anything on its own — see [Settings window](#8-settings-window)); it sends nothing about you or your clipboard, just an anonymous request for the latest release tag.

## 2. Requirements

- **macOS 14 (Sonoma) or later**
- **Apple Silicon or Intel** — either Mac works
- **Accessibility permission** (optional) — only needed so Clipnest can type your paste directly into the app you were using, and so snippet keyword-expansion can work. Everything else (capturing, browsing, and searching your history) works without it.
{: .detail-list}

## 3. Install

### One-line install (recommended)

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

</div>

Clipnest installs into your Applications folder and launches. To update later:

<div class="install-card" markdown="1">

<div class="terminal-bar"><span></span><span></span><span></span></div>

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
```

</div>

### Download the `.dmg`

Grab the latest `.dmg` from the project's [Releases](https://github.com/AayushGour/clipnest/releases) page, open it, and drag **Clipnest** into your Applications folder.

### First launch — signing, honestly

<div class="notice" markdown="1">

Clipnest isn't distributed through the Mac App Store, and it isn't signed with a notarized Apple Developer ID by default — but the **recommended one-line install** above doesn't trigger any Gatekeeper dialog at all. Here's why: macOS's "unidentified developer" check is triggered by the `com.apple.quarantine` flag, and that flag is set by the *downloader* (Safari, Chrome, Mail, AirDrop…), not by the app itself — `curl` never sets it. In its place, `install.sh`/`update.sh` verify the downloaded `.dmg` against a SHA-256 checksum published alongside every release, and refuse to install anything unverifiable.

</div>

Every release is still signed — with one long-lived, self-signed certificate, not a throwaway ad-hoc identity — which is exactly what lets your Accessibility grant survive updates instead of needing to be re-added every release (see [First launch & permissions](#4-first-launch--permissions)).

**If you instead download the `.dmg` directly from the Releases page** (see [Install](#3-install)), your browser *will* set the quarantine flag, and macOS Gatekeeper *will* say Clipnest is from an "unidentified developer" the first time you open it. To get past that **once**:

- **Right-click (or Control-click) Clipnest in Applications → Open** → click **Open** again in the dialog that appears, **or**
- Run this in Terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/Clipnest.app
  ```

After that first launch, Clipnest opens normally like any other app. Switching to the one-line `curl` install above avoids this step entirely.

## 4. First launch & permissions

When Clipnest first launches, it sits quietly in your menu bar — no setup wizard, no window to click through. Clipboard capture, browsing, and search all work immediately with no permissions granted at all.

**Accessibility** is the one optional permission Clipnest asks for, and it's only needed for two things:

- **Pasting directly into the app you were using.** Without it, selecting an item in Clipnest still copies it to your regular clipboard — you just have to press ⌘V yourself to paste it. With it granted, Clipnest types the paste in for you automatically.
- **Snippet keyword expansion** (⌥⌘E) in other apps — this needs Accessibility on both of its internal paths (reading/replacing a selection directly, and its clipboard-based fallback for apps like VS Code or Slack), so without it, expansion won't work at all.

The **very first time** you launch Clipnest — and only that once, ever, per install — it automatically shows macOS's "Clipnest would like to control this computer" Accessibility dialog for you, so there's nothing to hunt down on day one. Whether you grant it, dismiss it, or ignore it, Clipnest never shows that dialog again on its own: a paste attempt made while Accessibility isn't granted just silently falls back to clipboard-only (press ⌘V yourself) instead of re-prompting, and neither opening the picker nor pressing ⌥⌘E triggers it either. If ⌥⌘E just beeps and does nothing, that means Accessibility isn't granted — grant it manually (see below).

**To grant it (or bring back that one-time dialog on your own terms):** System Settings → Privacy & Security → Accessibility → turn on **Clipnest** — or open **Settings → Permissions** (**⌘,**) and click **Grant Accessibility…**, which shows the same system dialog on demand and is never rate-limited (see [Settings window](#8-settings-window)).

**If you build Clipnest from source yourself:** every fresh Debug build has a new, unsigned code identity, so macOS may ask you to re-grant Accessibility after each rebuild — and if System Settings still shows Clipnest as granted but nothing actually works after an update or rebuild, see [Settings window → Permissions](#8-settings-window) for the real fix (toggling it off and back on doesn't work).

## 5. Clipboard history

### How capture works

Clipnest checks the system clipboard a few times a second and, whenever something new appears, saves a copy — text, rich text, links, images, and files are all recognized. Copying the exact same content again doesn't create a duplicate entry; it just bumps the existing one back to the top of your history.

### Opening the picker

Press **⌥⌘V** (Option+Command+V) from anywhere — even inside a full-screen app — and the picker pops up right next to your mouse cursor. You can also click the Clipnest icon in the menu bar and choose **Open Clipnest**.

The picker never steals keyboard focus from the app you were using until you actually select something, so you can safely open it, look around, and press Esc to go right back to what you were doing.

### Searching

The search field is focused automatically as soon as the picker opens — just start typing. Matches are highlighted in the list. Press **⌘F** at any point to jump back to the search field (handy after arrowing through results).

### Filtering by type

Next to the search field, a row of small icon chips lets you narrow the current tab down to one kind of content: **All**, **Text**, **Image**, **File**, or **Link**. Click a chip to filter, click **All** to clear it. (These chips aren't shown on the Snippets tab, since snippets don't have a "kind.")

### Tabs

The picker has three tabs, switchable by clicking or with **⌘1 / ⌘2 / ⌘3**:

| Tab | Shortcut | Shows |
| --- | --- | --- |
| History | `⌘1` | Everything captured, newest first |
| Pinned | `⌘2` | Only items you've pinned, ordered by when you pinned them |
| Snippets | `⌘3` | Your saved snippets |

### Pasting an item

Highlight an item (click it, or arrow to it) and press **Return** — Clipnest pastes it into whatever app was frontmost before you opened the picker. If the source item had rich formatting, Return keeps it; press **⌥Return** instead to strip it down to plain text. (An image with recognized text behaves a little differently — see [Recognizing text in screenshots](#recognizing-text-in-screenshots-optional-ocr).)

If Accessibility isn't granted, "pasting" just places the item on your regular clipboard — press ⌘V yourself to finish the paste.

### Pinning

Press **⌘P**, click the pin icon on a row, or right-click → Pin/Unpin. Pinned items move out of History and into the **Pinned** tab so your most-used items are always easy to find again.

### Deleting

Press **⌘⌫** (or plain Delete), click the trash icon on a row, or right-click → Delete, to remove an item for good (this also frees up the disk space it was using, for images/rich text).

### Hovering for a full preview

Hover your pointer over any row (or arrow to it) and a preview panel appears beside the picker after a brief pause:

- **Images** render at up to 40% of your screen's width — with any recognized text shown underneath, scrollable on its own, if you've turned on OCR (see [Recognizing text in screenshots](#recognizing-text-in-screenshots-optional-ocr) below).
- **Text** (including rich text and links) shows the full content, scrollable — it loads in chunks as you scroll for very large clips, so nothing hangs.
- **Files** show the name, size, and full path — read from what was captured at copy time, not the live file, so it works even if the file has since moved.

### Recognizing text in screenshots (optional OCR)

Turn on **"Recognize text in copied images"** in **Settings → History** (off by default — see [Settings window](#8-settings-window)) and Clipnest reads the text in a screenshot right on your Mac, using Apple's Vision framework: no upload, no model download, no network call of any kind. Once it's on, a **Fast** / **Accurate** quality choice controls how thorough the recognition is — **Accurate is the default**; it reads punctuation, digits, and arrows correctly but takes a little longer per screenshot, while Fast is quicker but can confuse similar characters (like `1` and `l`). Neither can read keyboard symbols such as ⌘ ⌥ ⇧.

Once an image has recognized text:

- It's shown in the hover preview, underneath the image itself.
- It becomes part of that item's searchable content, alongside everything else.
- **⌥Return** pastes the recognized text as plain text instead of the image (plain **Return** still pastes the image itself).
- Right-click an image row → **Copy Recognized Text** copies just the text to your clipboard without dismissing the picker.
- **Settings → History** also has a one-off **Recognize Text in Existing Images** button that runs recognition over images you captured before turning the toggle on — it doesn't run automatically on old items otherwise.

<div class="notice" markdown="1">

Turning this on is a real privacy trade-off: recognized text becomes indexed, searchable content stored alongside the image, so a screenshot of a password or anything else sensitive turns that into searchable text on disk — which is exactly why it's **off by default**. It never runs on anything Clipnest wouldn't have captured anyway — concealed/transient copies and excluded apps are filtered out before an item is even captured (see [Privacy & exclusions](#7-privacy--exclusions)), so recognition never sees them either.

</div>

### How much history does Clipnest keep?

By default, Clipnest automatically keeps only the most recent **1,000** items, trimming older ones as new ones arrive — it isn't unlimited out of the box. Open **Settings → History** (**⌘,** — see [Settings window](#8-settings-window)) to change this: cap it by a different number of items, cap it by age instead (30 days by default), or switch to **Everything** to turn the cap off and keep everything until you delete it yourself. **Pinned items are never counted against the cap**, no matter which mode you pick. That same tab also has a **Clear All History…** button to wipe everything at once (including pinned items, after a confirmation), or you can remove Clipnest's whole data folder yourself (see [Uninstall](#11-uninstall)).

## 6. Snippets

Snippets are text you write yourself — a signature, a boilerplate reply, a shell command — as opposed to things Clipnest captured automatically. Each snippet has two fields:

- **Tag** — a short name. This is also what you type to trigger expansion.
- **Body** — the full text that gets pasted in when the Tag expands.

### Creating a snippet

- On the **Snippets** tab, press **⌘N** or click the **+** button, or
- From any item on the History/Pinned tabs, press **⌘S** (or right-click → **Save as Snippet**) to open the editor with the Body already filled in from that clip — you just add a Tag. (This only works for text and link items.)

A small editor window opens beside the picker. Fill in the Tag and Body and click **Save** (or Cancel to discard). Both fields are required.

### Editing or deleting a snippet

On the Snippets tab, right-click a snippet → **Edit** or **Delete**, or use the always-visible pencil/trash icons on the row.

### Pasting a snippet from the picker

Just like History/Pinned: highlight a snippet on the Snippets tab and press **Return** to paste its Body.

### Expanding a snippet by keyword, anywhere

This is the fast path — you don't need to open Clipnest at all:

1. Type a snippet's **Tag** in any app.
2. Select it (highlight the text you just typed).
3. Press **⌥⌘E** (Option+Command+E).

Clipnest replaces the selected text with that snippet's Body. For example, if you have a snippet with Tag `sig` and Body `Best,\nAlex`, typing `sig`, selecting it, and pressing ⌥⌘E turns it into your signature.

Matching is case-insensitive and ignores surrounding whitespace, so `SIG`, `sig `, and `Sig` all match a Tag of `sig`.

If nothing is selected, or the selected text doesn't match any Tag, you'll hear a system beep and nothing changes.

**Why this works everywhere:** Clipnest first tries to read and replace the selection directly through macOS's Accessibility API (this never touches your clipboard). In apps where that isn't possible — Electron/Chrome-based apps like VS Code or Slack are common examples — it falls back to simulating a copy and paste instead, and carefully snapshots your existing clipboard beforehand and restores it afterward, so your clipboard ends up exactly as it was. Both paths require Accessibility to be granted (see [First launch & permissions](#4-first-launch--permissions)).

## 7. Privacy & exclusions

Clipnest is built to never see or store things it shouldn't:

- **Password managers are ignored automatically**, with no setting that can turn this off. 1Password, Bitwarden, LastPass, Dashlane, and Keeper are excluded by default whenever a copy comes from one of those apps.
- **"Don't record this" copies are always honored.** Many apps (password managers among them) mark a copy as *concealed* or *transient* using a standard macOS clipboard convention — Clipnest checks for this marker first, before anything else, and it can never be bypassed.
- **No content ever appears in logs.** If something goes wrong internally, Clipnest logs only metadata (an item's ID, an error type) — never the text, image, or file content involved.
- **Nothing you copy, paste, or save as a snippet ever leaves your Mac.** There are no servers, no sync, no telemetry, and no account. The one narrow exception is a background check against GitHub's public Releases API, about once a day, to see whether a newer version exists — it's on by default, can be turned off in **Settings → General** (see [Settings window](#8-settings-window)), never downloads or installs anything on its own, and sends nothing about you or your clipboard, just an anonymous request for the latest release tag.
{: .detail-list}

### Where your data lives on disk

Everything Clipnest stores lives under one folder in your user Library:

```
~/Library/Application Support/Clipnest/
├── ClipItems.store     # clipboard history (metadata)
├── Snippets.store      # your snippets
└── blobs/              # image & rich-text content, deduplicated by content hash
```

Nothing here is synced or backed up anywhere outside your normal Mac backups (e.g. Time Machine, if you use it).

## 8. Settings window

Everything about how Clipnest behaves lives in one Settings window, opened with **⌘,** from the picker or the menu-bar icon. It has five tabs:

| Tab | What it controls |
| --- | --- |
| **General** | Launch Clipnest at login, pause clipboard capture with one toggle, and turn the background update check on/off (see [What is Clipnest](#1-what-is-clipnest)). |
| **History** | How much history is kept (see [How much history does Clipnest keep?](#how-much-history-does-clipnest-keep)), the "Recognize text in copied images" OCR toggle and its Fast/Accurate quality (see [Recognizing text in screenshots](#recognizing-text-in-screenshots-optional-ocr)), and **Clear All History…**. |
| **Shortcuts** | Rebind Clipnest's two global hotkeys — **Open Clipnest** and **Expand snippet** — to whatever key combination you want. Click a shortcut, then press the new combination; it takes effect immediately, no restart needed. (This only rebinds the two *global* shortcuts — the shortcuts inside the picker itself, listed below, are fixed.) |
| **Apps** | Exclude specific apps from capture, on top of the built-in password-manager list (always on, can't be removed — see [Privacy & exclusions](#7-privacy--exclusions)). Add an app by picking its `.app` bundle from a file picker; remove one with its **−** button. |
| **Permissions** | See whether Accessibility is granted, grant it on demand, or jump straight to System Settings. Also the one place that explains a real gotcha: because Clipnest is signed locally, an update or a rebuild can leave System Settings still showing Clipnest as granted while it no longer actually is. The fix is to remove Clipnest from the Accessibility list with the **−** button and add it again — toggling the switch off and on does not fix it. |

Opening Settings briefly shows a Dock icon while that window is focused — Clipnest goes back to menu-bar-only, no Dock icon, the moment you close it. That's expected, not a bug.

## 9. Keyboard shortcuts reference

### Global (work from any app)

| Action | Shortcut |
| --- | --- |
| Open/toggle the picker | `⌥⌘V` |
| Expand a snippet by Tag | `⌥⌘E` |

### Inside the picker

| Action | Shortcut |
| --- | --- |
| Move selection up / down | `↑` / `↓` |
| Paste selected item / snippet | `Return` |
| Paste without formatting | `⌥Return` |
| Focus the search field | `⌘F` |
| Pin / unpin highlighted item | `⌘P` |
| Save highlighted item as a snippet | `⌘S` |
| New snippet *(Snippets tab)* | `⌘N` |
| Delete highlighted item / snippet | `⌘⌫` (or `Delete`) |
| Switch to History tab | `⌘1` |
| Switch to Pinned tab | `⌘2` |
| Switch to Snippets tab | `⌘3` |
| Open Settings | `⌘,` |
| Close the picker | `Esc` |

The two **global** shortcuts above — **Open/toggle the picker** and **Expand a snippet by Tag** — are rebindable from **Settings → Shortcuts** (**⌘,**): click a shortcut field and press your preferred key combination; it takes effect immediately (see [Settings window](#8-settings-window)). The shortcuts *inside* the picker (search, pin, delete, switch tabs, and so on, listed in the table above) are fixed and aren't currently customizable.

`⌘,` (Command+Comma) also opens Settings while the Settings window itself is focused — the standard macOS convention — but it is deliberately **not** a global shortcut: unlike `⌥⌘V`/`⌥⌘E` above, it only works from inside the picker or from Settings itself, so it never takes `⌘,` away from whatever other app you're using (that app's own Preferences/Settings shortcut keeps working normally).

## 10. Troubleshooting

**Clipnest isn't capturing anything I copy.**
Check whether you're copying from a password manager (1Password, Bitwarden, LastPass, Dashlane, Keeper) — those are deliberately never captured, by design. If it's a different app, make sure Clipnest is actually running (look for its icon in the menu bar) — if it quit or crashed, nothing will be captured until you relaunch it.

**⌥⌘V (or ⌥⌘E) doesn't do anything.**
Another app may already be using that combination — a common source of silent conflicts with global hotkeys. Either quit or check the shortcut settings of whatever else might claim Option+Command+V or Option+Command+E (menu-bar utilities, window managers, other clipboard tools), or just rebind Clipnest's own shortcut instead: open **Settings → Shortcuts** (**⌘,**) and record a new key combination for **Open Clipnest** or **Expand snippet** (see [Settings window](#8-settings-window)).

**Paste puts the item on my clipboard but doesn't type it into the app.**
This means Accessibility isn't granted. Turn it on from System Settings → Privacy & Security → Accessibility, or from **Settings → Permissions** in Clipnest itself (see [Settings window](#8-settings-window)). Granting a permission never takes effect for a paste that's already in progress — press ⌘V once yourself to finish that one, and every paste after that should work automatically.

**⌥⌘E just beeps and nothing happens.**
Either nothing is selected (make sure you've actually highlighted the Tag text before pressing the shortcut), the Tag doesn't match any snippet exactly, or Accessibility isn't granted (see above — unlike a picker paste, expansion won't prompt you for the permission on its own).

**macOS says Clipnest is from an "unidentified developer" / won't open.**
This means you downloaded the `.dmg` directly through a browser rather than using the one-line `curl` install — a browser download sets the quarantine flag that triggers this Gatekeeper check, but `curl` never does. See [First launch — signing, honestly](#3-install): right-click → Open once, or run `xattr -dr com.apple.quarantine /Applications/Clipnest.app`, or just switch to the recommended `curl` install and this won't come up again.

**I rebuilt Clipnest from source and it's asking for Accessibility again.**
Expected — an unsigned development build gets a new code identity on every rebuild, so macOS treats it as a "new" app each time and needs Accessibility re-granted.

**I don't see a Dock icon or a normal app window — is that right?**
Yes. Clipnest is a menu-bar-only app by design; look for its icon in the menu bar, and use ⌥⌘V or that menu to reach it. (Opening Settings briefly shows a Dock icon while that window is focused — that's expected, and it goes away again once you close Settings.)

## 11. Uninstall

Drag **Clipnest** from Applications to the Trash, then, if you also want to remove your data:

```bash
rm -rf ~/Library/Application\ Support/Clipnest \
       ~/Library/Preferences/com.clipnest.app.plist \
       ~/Library/Caches/com.clipnest.app \
       ~/Library/HTTPStorages/com.clipnest.app
```

Everything Clipnest stores is local to those folders — removing them leaves nothing behind.
