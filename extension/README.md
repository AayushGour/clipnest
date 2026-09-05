# Clipnest GNOME Shell extension

Optional. Clipnest works without it — but on a Wayland session it supplies the
capabilities a Wayland client structurally cannot have on its own.

## Why it exists

| Capability | Without the extension | With it |
|---|---|---|
| Clipboard while unfocused | Works, via mutter's XWayland selection bridge | Works, natively |
| Picker at the cursor | **Centred on the pointer's monitor** — a Wayland client cannot position itself | At the cursor |
| Above fullscreen windows | Unavailable | `make_above()` |
| Verified paste target | Unavailable, so auto-paste defaults off | Atomic focus+chord, race-free |
| App identity for privacy exclusions | **Unavailable for native Wayland apps** — mutter reports its `no_focus_window` sentinel | Full, via `Shell.WindowTracker` |

The last row matters most: without the extension, app-based exclusions and the
password-manager denylist silently cannot apply to native Wayland apps. The
marker-based filter (`x-kde-passwordManagerHint`) still works everywhere.

## Layout

`src/core/` imports nothing and receives its GI namespaces by injection, so one
source tree serves both the pre-45 `imports.gi` world and the 45+ ESM world.
GJS < 1.76 cannot *parse* `import x from 'gi://X'`, so a single file genuinely
cannot serve both — `build.sh` emits `dist/legacy` (Shell 42–44) and
`dist/esm` (Shell 45–50).

The only non-ESM API break across 42→50 among everything used here is
`Meta.later_add` moving to `global.compositor.get_laters().add()` at Shell 44,
absorbed by the shims.

## Safety properties

- No monkey-patching of shell internals, ever. No panel UI — the tray icon is
  the app's own StatusNotifierItem, so there is nothing here to visually break.
- Every feature module enables inside its own try/catch, so a module that
  breaks on a future GNOME release drops one `Capabilities` entry rather than
  taking clipboard watching down with it.
- Every D-Bus method is sender-checked against the owner of
  `app.clipnest.Clipnest`. This service can read the clipboard and inject
  keystrokes; it must not become a capability any app on the session bus can
  borrow.
- `disable()` is idempotent and never throws.

## Build

    ./build.sh

Installed per-user by the app (not by the .deb) so it can pick the right
variant at runtime and survive app upgrades without root.
