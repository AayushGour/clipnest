# Testing Clipnest 0.9.1 on Linux

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
tar xzf clipnest-0.9.1-linux-amd64.tar.gz
cd clipnest-0.9.1-linux-amd64
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

Every row also has pin / save-as-snippet / delete buttons, and a right-click menu.

`Delete` deliberately edits the search text when the caret has something to
delete, and acts on the highlighted item otherwise — matching macOS. An earlier
version deleted the item unconditionally, which destroyed clips while typing.

---

## 3. Worth testing first — NEVER TESTED ON REAL HARDWARE

These were proven only in a synthetic GNOME Shell. Real hardware is the real test.

1. **Global hotkey.** Press `Alt+Super+V`. Does the picker open at your cursor?
   Check which backend it chose: `grep "hotkey backend resolved" <(clipnest 2>&1)`
   or look at stderr. `shellExtensionKeybinding` means the extension path is
   live; `gsettingsFloor` is the fallback.
2. **GNOME Shell extension** (optional, unlocks cursor placement and
   above-fullscreen):
   ```bash
   gnome-extensions install --force /usr/share/clipnest/gnome-shell-extension/esm      # GNOME 45+
   gnome-extensions install --force /usr/share/clipnest/gnome-shell-extension/legacy   # GNOME 42-44
   ```
   Then **log out and back in** — GNOME only discovers a brand-new extension on
   Shell startup — and enable it in the Extensions app.
3. **Wayland.** Log into a Wayland session and check capture still works
   (copy in any app, confirm it appears). Capture goes through Mutter's XWayland
   clipboard bridge; this is the least-tested path in the whole port.
4. **Auto-paste.** Settings → Permissions → grant, then **log out and back in**.
   Without it Clipnest copies and you paste manually.
5. **Multi-monitor and fractional scaling.** Never tested at all.

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
  GTK4 window (see `docs/API-ClipnestPlatformLinux.md`); a real bug in
  reading the AT-SPI selection was found and fixed by that verification, so
  earlier builds always fell through to the clipboard path regardless of app.
  Coverage is still realistic, not universal — GTK4 works; GTK3/Qt need
  `toolkit-accessibility` enabled (untested); Electron and terminal
  emulators miss and fall back to clipboard, same as before.

---

## 5. If something breaks

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
