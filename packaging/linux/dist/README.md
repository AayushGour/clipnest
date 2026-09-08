# Installing Clipnest from a downloaded release

This directory's contents (three `.deb` files plus their `.sha256`
checksums, downloaded together from a GitHub Release) are what
`install.sh` in this same folder expects to sit next to. Run it:

```sh
./install.sh
```

It verifies your machine's architecture matches the `.deb`s, then installs
`clipnest`, `clipnest-ocr`, and `clipnest-ocr-data` via `apt-get install
./*.deb` (so `apt` still resolves and installs their real runtime
dependencies from your normal repositories).

## Known limitation on Ubuntu 22.04 (and any system with GTK 4 < 4.10)

Clipnest depends on your system's GTK 4 library (`libgtk-4-1`). A rare bug
in GTK versions before 4.10 — not in Clipnest — can make Clipnest quit
unexpectedly if another running application interacts with the clipboard
in an unusual way (a real but uncommon protocol slip some other app makes,
not anything Clipnest does). This was fixed upstream in GTK 4.10.

- **Ubuntu 22.04 (jammy)** ships GTK 4.6.9 — affected. `install.sh` checks
  your installed `libgtk-4-1` version and prints a note about this if it's
  older than 4.10; Clipnest itself repeats the same explanation, with your
  exact detected version, under **Settings > Permissions** every time it
  starts on an affected system.
- **Ubuntu 24.04 (noble) and newer** already ship a fixed GTK 4 — this
  does not apply to you.
- This never affects your clipboard history: the history store is
  separate from GTK's own clipboard-tracking code and survives this crash
  intact. If it happens, just reopen Clipnest.
- We looked for a trustworthy backported GTK 4 ≥ 4.10 package for Ubuntu
  22.04 (checked Ubuntu's own archive and backports pocket, plus several
  well-known GNOME-stack PPAs directly against Launchpad) and found none
  currently maintained. The only real fix today is upgrading to Ubuntu
  24.04 or newer; short of that, keep using Clipnest normally — this
  crash requires another, separately-buggy application to trigger it, and
  reopening Clipnest costs you nothing.

Full technical root cause: `debian/README.source`'s "Known gap #5" in
this project's source repository.

## Two more things worth knowing

1. **Auto-paste needs one extra permission.** Open Settings ->
   Permissions and grant it there. It adds you to the `clipnest-input`
   group, which allows creating a virtual keyboard device and nothing
   else — not the `input` group, which would let any program read your
   real keystrokes. Log out and back in for the new group membership to
   take effect. Without it, Clipnest still copies items to your
   clipboard; you paste manually.
2. **The GNOME Shell extension is optional.** Clipnest works without it.
   With it, the picker can open at your cursor and appear above
   fullscreen windows:
   ```sh
   gnome-extensions install --force \
     /usr/share/clipnest/gnome-shell-extension/<variant>
   ```
   Pick `esm` for GNOME 45+, `legacy` for GNOME 42-44. Then log out and
   back in.
