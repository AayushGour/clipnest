# Testing Clipnest 1.0.0 on Linux

**Temporary file** — delete this and `dist/` once testing is done.

Everything below was verified in containers (including a real GNOME Shell 42.9
under systemd). **Your machine is the first physical hardware this has ever run
on**, so the interesting failures are most likely in the sections marked
NEVER TESTED ON REAL HARDWARE.

---

## 1. Install

```bash
git clone -b linux-migration https://github.com/AayushGour/clipnest.git
cd clipnest/dist

uname -m                       # x86_64 -> amd64,  aarch64 -> arm64
tar xzf clipnest-1.0.0-linux-amd64.tar.gz
cd clipnest-1.0.0-linux-amd64
./install.sh
```

The installer refuses to run if the package architecture does not match the
machine, so a wrong download fails clearly instead of confusingly.

Lighter install without OCR (saves ~26 MB): `sudo apt-get install
--no-install-recommends ./clipnest_*.deb`

---

## 2. Run

```bash
clipnest &                      # start it
clipnest-ctl toggle-picker      # open/close the picker
clipnest-ctl open-settings      # Settings
clipnest-ctl ping               # is it alive
clipnest --version
```

Global hotkey defaults to **Alt+Super+V**, rebindable in Settings → Shortcuts.

### Picker keys

| | |
|---|---|
| `↑` `↓` | move · `Enter` paste · `Alt+Enter` paste as plain text |
| `Ctrl+F` | search · `Ctrl+P` pin · `Ctrl+1/2/3` tabs |
| `Delete` | delete highlighted (only when the search box is empty — see below) |
| `Ctrl+S` | save as snippet · `Ctrl+N` new snippet · `Ctrl+Shift+E` replace |
| `Ctrl+,` | Settings · `Esc` close |

The footer's `Enter` hint reflects what will actually happen: it reads
**"Enter paste"** when an auto-paste backend (uinput or XTEST) is available,
and **"Enter copy"** when it is not (e.g. a Wayland session without the
`clipnest-input` group grant, which needs a re-login to take effect — see
Settings → Permissions). On the first paste attempt of the process without
auto-paste, a one-time notice also appears: "Copied to clipboard — press
Ctrl+V to paste. Auto-paste isn't set up on this session — see Settings →
Permissions." Either way the item is copied to the clipboard; the difference
is only whether Clipnest can also synthesize the paste keystroke for you.

**First-run "Set Up Auto-Paste?" prompt.** On a session where no auto-paste
backend is available at all (the same condition as "Enter copy" above),
Clipnest now proactively asks about this at startup instead of only
explaining it after you've already hit it — a modal dialog with **Grant
Access…** (runs the same `pkexec clipnest-grant-input` flow as Settings →
Permissions, right from the dialog) and **Not Now**. It explains what
auto-paste unlocks, states plainly that it needs a logout/login to take
effect, and is honest that Clipnest works fine without it. Shown at most
once ever (persisted in `~/.config/clipnest/settings.json`) — dismissing it
either way never shows it again; grant it later from Settings → Permissions
if you skip it here. It never appears at all on a session that already has
auto-paste (X11 via XTEST, or uinput already granted).

Every row also has pin / save-as-snippet / delete buttons, and a right-click menu.

`Delete` deliberately edits the search text when the caret has something to
delete, and acts on the highlighted item otherwise — matching macOS. An earlier
version deleted the item unconditionally, which destroyed clips while typing.

---

## 3. Real-hardware results (Ubuntu 24.04.5, GNOME 46, Wayland — 2026-10-02)

First run on physical hardware (ThinkPad, single 1920×1200 display), driven
with synthetic uinput keyboard/pointer input plus portal screenshots.

**Works:** the `Alt+Super+V` hotkey (`gsettingsFloor` backend) opens the
picker focused and searchable; tray → Open Clipnest; capture of
Wayland-native and XWayland copies (text, rich text, images, files);
auto-paste via uinput into GTK apps and Chrome; snippet expansion in GTK
apps (AT-SPI tier) and Chrome (IBus tier); Settings; tray menu; OCR (once
enabled in Settings → History — it is off by default).

**Found broken and fixed in this pass:**
- **Picking an item froze Clipnest** ("not responding") whenever auto-paste
  wasn't set up — the board's open P0 (T-HANG-SELECT1). Reproduced under
  gdb: the GTK thread was waiting on a clipboard read served by that same
  thread. Clipnest's writes now carry a private marker type
  (`application/x-clipnest-owned`) and are never read back.
- The picker never dismissed when another window took focus. It stayed
  open behind that window, and the next hotkey press closed it instead of
  opening it. (GTK4 keeps `is-active` TRUE across a hide on Wayland.)
- **Password-manager copies were saved to history.** The hinted copy itself
  was refused, but GNOME re-publishes clipboard text without the hint once
  the source app lets go (KeePassXC's clear-after-N-seconds does exactly
  that), and Clipnest captured that copy.
- Settings offered "Update to v0.9.2" to a v0.9.4 install, i.e. a downgrade
  with a working Install button. `scripts/update.sh` (macOS) had the same
  rule; both now update only to a strictly newer version.
- Picking an item into a terminal typed `^V` instead of pasting. Terminals
  are now detected through AT-SPI and get Ctrl+Shift+V.
- The tray menu had no "Pause Capture" toggle (macOS has one). Added.

**Expected, not bugs:** without the Shell extension the picker opens at the
top-left, not at the cursor, and Wayland-native copies have no source app
(so Settings → Apps exclusions only match XWayland apps). "Launch Clipnest
at login" is off by default, as on macOS, so nothing is captured after a
login until you open the picker once. Turn it on in Settings → General.

### Still untested on real hardware

1. **GNOME Shell extension** (optional, unlocks cursor placement and
   above-fullscreen):
   ```bash
   gnome-extensions install --force /usr/share/clipnest/gnome-shell-extension/esm      # GNOME 45+
   gnome-extensions install --force /usr/share/clipnest/gnome-shell-extension/legacy   # GNOME 42-44
   ```
   Then **log out and back in** — GNOME only discovers a brand-new extension on
   Shell startup — and enable it in the Extensions app.
   With it, the hotkey should report `shellExtensionKeybinding`
   (`journalctl --user -t clipnest | grep "hotkey backend resolved"`) and the
   picker should open at the cursor.
2. **The first-run "Set Up Auto-Paste?" prompt.** This machine already had
   the `clipnest-input` grant, so the prompt never showed.
3. **X11 sessions, multi-monitor, fractional scaling.**

---

## 4. Known issues — expected, not worth reporting

- **Ubuntu 22.04 shows a GTK warning in Settings.** Correct and deliberate.
  22.04 ships GTK 4.6.9, which has a NULL-dereference in its own X11 clipboard
  code that another misbehaving app can trigger; it crashes Clipnest with it.
  Not our bug, unreachable from our code, fixed upstream in GTK ~4.10.
  **Ubuntu 24.04 ships 4.14.5 and is unaffected** — prefer it if you can.
- Picker does not clamp to the monitor work area, so near a screen edge it can
  overflow.
- A second hotkey press may not toggle the picker closed (seen once, not
  reproduced from a clean state).
- Snippet expansion prefers an in-place AT-SPI replace (no clipboard touched)
  when the focused app exposes it, falling back to the clipboard round-trip
  otherwise. Verified for real against a live accessibility bus and a real
  GTK4 window (see `docs/API-ClipnestPlatformLinux.md`). As of 0.9.2, every
  AT-SPI insertion is verified by reading the affected text range back after
  a successful reply and comparing it to what was sent — mirroring the
  macOS AX trust contract — so a phantom "succeeded" reply that never
  actually landed falls back to the clipboard path instead of silently
  leaving the buffer unexpanded. Coverage is still realistic, not universal
  — GTK4 works; GTK3/Qt need `toolkit-accessibility` enabled (untested);
  Electron and terminal emulators miss and fall back to clipboard, same as
  before.
- When no auto-paste backend is available, the picker now says so instead
  of silently doing nothing — see the `Enter` hint note under "Picker keys"
  above (0.9.2).

---

## 5. Build and install from source (developers)

```bash
make test-linux      # swift test in Docker (no host Swift needed)
make lint            # swift-format via scripts/lint.sh
make deb             # local .debs into build/linux/ (version gets a +local<timestamp> suffix)
make install-linux   # deb + pkexec apt-get install (GUI password prompt) + restart the app
make restart         # kill and relaunch the installed app
make logs            # journalctl --user -t app.clipnest.Clipnest -f
make uninstall-linux # pkexec apt-get remove
```

`make` lists every target; see the README's "Make targets" section.

### Checks for the 1.0.1 picker fixes

- Copy something, open the picker, press Enter on an older item: that item (not
  the last copy) is pasted. Press Enter twice quickly: it pastes once.
- Hover a row: the preview appears beside the picker, level with the row, on
  Wayland too, and stays open (scrollable) while the pointer is over it. Same on
  the Snippets tab.
- Settings → General → *Show preview when selecting with the keyboard* on: arrow
  keys show the preview beside the selected row; off: they don't.
- Arrow through a long list: the selected row stays in view. A 200-line copy
  shows 3 lines in its row.
- A copy that is not captured (e.g. concealed) logs a reason:
  `journalctl --user -t app.clipnest.Clipnest --since '-5min'`.

## 6. If something breaks

```bash
clipnest 2>&1 | tee /tmp/clipnest.log     # run in a terminal, keep the log
sqlite3 ~/.local/share/Clipnest/ClipItems.sqlite3 'select count(*) from clip_items;'
gnome-extensions info clipnest@clipnest.app     # if using the extension
journalctl --user -b | grep -i clipnest
```

Useful to include: `uname -m`, `lsb_release -d`, `echo $XDG_SESSION_TYPE`
(x11 or wayland), `pkg-config --modversion gtk4`, and whether the extension is
enabled.

Your data lives in `~/.local/share/Clipnest/` (history and snippets, SQLite) and
`~/.config/clipnest/settings.json`. Uninstalling never deletes it — `apt-get
purge` deliberately leaves the data directory alone.
