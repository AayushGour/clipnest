# Using Clipnest

A guide for everyday use — install, permissions, clipboard history, snippets, and troubleshooting.

> Looking for the developer/API reference instead? See [`docs/API.md`](API.md).

## 1. What is Clipnest

Clipnest is a small, native menu-bar app for Mac that quietly remembers everything you copy — text, links, images, and files — so you can search back through it and paste it again later. It also has **Snippets**: reusable bits of text you write yourself, which you can drop into any app by typing a short keyword.

Clipnest lives only in the menu bar (there's no Dock icon, no window that stays open) and is entirely private: **nothing you copy or type into Clipnest ever leaves your Mac.** There's no account, no cloud sync, no analytics, and no network access at all — everything is stored in a local database in your user Library folder.

## 2. Requirements

- **macOS 14 (Sonoma) or later**
- **Apple Silicon or Intel** — either Mac works
- **Accessibility permission** (optional) — only needed so Clipnest can type your paste directly into the app you were using, and so snippet keyword-expansion can work. Everything else (capturing, browsing, and searching your history) works without it.

## 3. Install

### One-line install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/install.sh | bash
```

Clipnest installs into your Applications folder and launches. To update later:

```bash
curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/update.sh | bash
```

### Download the `.dmg`

Grab the latest `.dmg` from the project's [Releases](https://github.com/AayushGour/clipnest/releases) page, open it, and drag **Clipnest** into your Applications folder.

### First launch — a Gatekeeper heads-up

Clipnest's builds aren't signed with an Apple Developer ID yet (unless a specific release notes otherwise), so the first time you open it, macOS Gatekeeper will say it's from an "unidentified developer" and refuse to launch it normally. To get past this **once**:

- **Right-click (or Control-click) Clipnest in Applications → Open** → click **Open** again in the dialog that appears, **or**
- Run this in Terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/Clipnest.app
  ```

After that first launch, Clipnest opens normally like any other app.

## 4. First launch & permissions

When Clipnest first launches, it sits quietly in your menu bar — no permission prompts, no setup wizard. Clipboard capture, browsing, and search all work immediately with no permissions granted at all.

**Accessibility** is the one optional permission Clipnest asks for, and it's only needed for two things:

- **Pasting directly into the app you were using.** Without it, selecting an item in Clipnest still copies it to your regular clipboard — you just have to press ⌘V yourself to paste it. With it granted, Clipnest types the paste in for you automatically.
- **Snippet keyword expansion** (⌥⌘E) in other apps — this needs Accessibility on both of its internal paths (reading/replacing a selection directly, and its clipboard-based fallback for apps like VS Code or Slack), so without it, expansion won't work at all.

Clipnest never prompts for Accessibility just from launching or opening the picker. The one place it *will* trigger the system's "Clipnest would like to control this computer" dialog is the moment you try to paste an item while Accessibility isn't yet granted — that specific paste still falls back to clipboard-only (granting a permission never takes effect instantly), but the *next* one will paste automatically. Snippet expansion doesn't trigger this dialog on its own — if ⌥⌘E just beeps and does nothing, grant Accessibility manually (see below).

**To grant it:** System Settings → Privacy & Security → Accessibility → turn on **Clipnest**.

**If you build Clipnest from source yourself:** every fresh Debug build has a new, unsigned code identity, so macOS may ask you to re-grant Accessibility after each rebuild.

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

Highlight an item (click it, or arrow to it) and press **Return** — Clipnest pastes it into whatever app was frontmost before you opened the picker. If the source item had rich formatting, Return keeps it; press **⌥Return** instead to strip it down to plain text.

If Accessibility isn't granted, "pasting" just places the item on your regular clipboard — press ⌘V yourself to finish the paste.

### Pinning

Press **⌘P**, click the pin icon on a row, or right-click → Pin/Unpin. Pinned items move out of History and into the **Pinned** tab so your most-used items are always easy to find again.

### Deleting

Press **⌘⌫** (or plain Delete), click the trash icon on a row, or right-click → Delete, to remove an item for good (this also frees up the disk space it was using, for images/rich text).

### Hovering for a full preview

Hover your pointer over any row (or arrow to it) and a preview panel appears beside the picker after a brief pause:

- **Images** render at up to 40% of your screen's width.
- **Text** (including rich text and links) shows the full content, scrollable — it loads in chunks as you scroll for very large clips, so nothing hangs.
- **Files** show the name, size, and full path — read from what was captured at copy time, not the live file, so it works even if the file has since moved.

### How much history does Clipnest keep?

There's currently no automatic limit or expiration — Clipnest keeps everything you copy until you delete it yourself (or delete your whole history — see [Uninstall](#10-uninstall)). Configurable retention (e.g. "keep the last 500 items" or "keep 30 days") is planned but not available yet.

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
- **Nothing leaves your Mac.** There are no servers, no sync, no telemetry, and no network calls anywhere in the app.

### Where your data lives on disk

Everything Clipnest stores lives under one folder in your user Library:

```
~/Library/Application Support/Clipnest/
├── ClipItems.store     # clipboard history (metadata)
├── Snippets.store      # your snippets
└── blobs/              # image & rich-text content, deduplicated by content hash
```

Nothing here is synced or backed up anywhere outside your normal Mac backups (e.g. Time Machine, if you use it).

## 8. Keyboard shortcuts reference

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
| Close the picker | `Esc` |

These shortcuts aren't yet customizable from within the app — a Settings window for rebinding them is planned but not shipped.

## 9. Troubleshooting

**Clipnest isn't capturing anything I copy.**
Check whether you're copying from a password manager (1Password, Bitwarden, LastPass, Dashlane, Keeper) — those are deliberately never captured, by design. If it's a different app, make sure Clipnest is actually running (look for its icon in the menu bar) — if it quit or crashed, nothing will be captured until you relaunch it.

**⌥⌘V (or ⌥⌘E) doesn't do anything.**
Another app may already be using that combination — a common source of silent conflicts with global hotkeys. Quit or check the shortcut settings of anything else that might claim Option+Command+V or Option+Command+E (menu-bar utilities, window managers, other clipboard tools). There's currently no in-app way to rebind Clipnest's own shortcuts, so the fix has to come from the other app.

**Paste puts the item on my clipboard but doesn't type it into the app.**
This means Accessibility isn't granted yet. Go to System Settings → Privacy & Security → Accessibility and make sure Clipnest is turned on. The paste attempt that triggered the permission dialog will still only copy to your clipboard — press ⌘V once yourself, and every paste after that should work automatically.

**⌥⌘E just beeps and nothing happens.**
Either nothing is selected (make sure you've actually highlighted the Tag text before pressing the shortcut), the Tag doesn't match any snippet exactly, or Accessibility isn't granted (see above — unlike a picker paste, expansion won't prompt you for the permission on its own).

**macOS says Clipnest is from an "unidentified developer" / won't open.**
This is Gatekeeper flagging an unsigned build — see [First launch](#3-install): right-click → Open once, or run `xattr -dr com.apple.quarantine /Applications/Clipnest.app`.

**I rebuilt Clipnest from source and it's asking for Accessibility again.**
Expected — an unsigned development build gets a new code identity on every rebuild, so macOS treats it as a "new" app each time and needs Accessibility re-granted.

**I don't see a Dock icon or a normal app window — is that right?**
Yes. Clipnest is a menu-bar-only app by design; look for its icon in the menu bar, and use ⌥⌘V or that menu to reach it.

## 10. Uninstall

Drag **Clipnest** from Applications to the Trash, then, if you also want to remove your data:

```bash
rm -rf ~/Library/Application\ Support/Clipnest \
       ~/Library/Preferences/com.clipnest.app.plist \
       ~/Library/Caches/com.clipnest.app \
       ~/Library/HTTPStorages/com.clipnest.app
```

Everything Clipnest stores is local to those folders — removing them leaves nothing behind.
