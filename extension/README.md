# Clipnest GNOME Shell extension

Optional. Clipnest works without it — but on a Wayland session it supplies the
capabilities a Wayland client structurally cannot have on its own.

## Why it exists

| Capability | Without the extension | With it |
|---|---|---|
| Clipboard while unfocused | Works, via mutter's XWayland selection bridge | Works, natively |
| Picker at the cursor | **Centred on the pointer's monitor** — a Wayland client cannot position itself | At the cursor |
| Above fullscreen windows | Unavailable | `make_above()` |
| Verified paste target | Unavailable, so auto-paste defaults off | Atomic focus+chord, race-free — **built here, not yet called by the app** |
| App identity for privacy exclusions | **Unavailable for native Wayland apps** — mutter reports its `no_focus_window` sentinel | Full, via `Shell.WindowTracker` — **built here, not yet called by the app** |

The last row matters most: without the extension, app-based exclusions and the
password-manager denylist silently cannot apply to native Wayland apps. The
marker-based filter (`x-kde-passwordManagerHint`) still works everywhere.

**Two rows are marked "not yet called by the app", and the distinction is
important.** `FocusAndSendKeyChord` and `GetFocusedApp` are implemented here and
verified live against a real Mutter (see `packaging/linux/gnome-shell-test/`),
but nothing on the Swift side invokes them: `ShellHelperClient` has no wrapper
for either, and `LinuxEventSynthesizerSelection.choose` never consults the
extension when picking a paste backend. So installing the extension does **not**
currently give you auto-paste or app-aware privacy exclusions on Wayland, however
much the mechanism exists. Wiring the paste half is tracked as `T-WLPASTE2`.
Until then, read the right-hand column as "what this extension can supply", not
"what Clipnest does with it today".

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

## Known GJS/GLib pitfalls (verified against real `gjs`, not assumed from docs)

- **Never call `GLib.unix_open_pipe()`/`GLibUnix.open_pipe()` from GJS.**
  `ClipboardWatcher.readToFd()` (`src/core/clipboard.js`) needs an anonymous
  pipe to stream the selection out over D-Bus. The documented way to get one
  is broken on every real `gjs` this extension was checked against — not a
  one-version regression:
  - gjs 1.72 (~Shell 42): throws `GLib.Error g-unix-error-quark: Bad
    address`.
  - gjs 1.80 (~Shell 46): same "Bad address" from both the old symbol and
    its replacement `GLibUnix.open_pipe`; passing an `Int32Array(2)`
    instead of a plain array avoids the exception but silently leaves both
    fds `0` — worse, not better.
  - gjs 1.82 (~Shell 48): the old call is now a flat `TypeError`;
    `GLibUnix.open_pipe` still throws "Bad address".

  Root cause is GJS's marshalling of the fixed-size `int fds[2]`
  (out/caller-allocates) parameter, not a kernel or sandbox restriction — a
  raw `pipe2()` syscall works fine in the same container. The fix,
  `ClipboardWatcher._makePipeSocketPair()`, builds a connected loopback
  `Gio.Socket` pair instead: no fixed-size array out-parameters anywhere in
  that path, and it moves real bytes end-to-end on gjs 1.72, 1.80, and 1.82
  alike (see `test/clipboard.readtofd.test.js`).
- **`Gio.UnixFDList.new_from_array()` takes ownership of the fd it's given
  — it does not `dup()` it** (unlike `.append()`, which does). Handing it a
  fd that some other live `Gio.Socket`/stream object also still owns is a
  real double-close: verified directly, it produces a
  `GLib-CRITICAL **: g_close(fd) failed with EBADF` when the second owner
  later closes its copy. `readToFd()` works around this by using a
  throwaway `Gio.UnixFDList` purely as a `dup(2)` primitive
  (`.append()` in, `.get()` out) so the fd handed to D-Bus is always an
  independent duplicate, never a fd this class still owns itself.

## D-Bus API (`app.clipnest.ShellHelper1`, `src/core/service.js`)

Full contract: `dbus/app.clipnest.ShellHelper1.xml`. Every member it declares
is implemented in `ShellHelperService` — 11 methods, 3 signals. Notes for
anyone calling this interface or extending its implementation:

- **Every method is implemented as `MethodNameAsync(args, invocation[, fdList])`**,
  even the synchronous ones. This isn't cosmetic: GJS's
  `Gio.DBusExportedObject` dispatcher only ever hands the `invocation` object
  (needed for the sender check every method performs) to a handler found
  under the `Async` suffix — a plain `MethodName(...)` never sees it. Method
  names must match the XML exactly; a typo here is a silent `UnknownMethod`
  the caller only discovers by getting no reply. `SetClipboardAsync` is the
  one member that is *also* genuinely asynchronous — it drains the incoming
  fd via `Gio.OutputStream.splice_async` rather than a blocking read, so a
  large clipboard payload cannot stall the compositor's main loop.
- **`a{sv}` values must be explicit `GLib.Variant` instances**, not raw JS
  primitives — `new GLib.Variant('a{sv}', {key: 'value'})` throws
  ("Expected an object of type GVariant … but got type string"). Use
  `ShellHelperService._variantDict(obj)` (boxes strings/booleans/numbers)
  before packing anything into `GetFocusedApp`'s `info` or
  `ShortcutActivated`'s `focus`. Verified directly under `gjs`, not assumed
  — see that method's doc comment.
- **`GetFocusedApp`'s `info` includes `window-serial`** (Mutter's
  `get_stable_sequence()`), the id `FocusAndSendKeyChord`'s `window_serial`
  argument resolves via `Placement.findWindowBySerial()`. This key isn't in
  the XML's own inline comment list because it's a resolution mechanism, not
  a distinct capability.
- **`SendKeyChord`/`FocusAndSendKeyChord`'s `modifiers` argument is a
  `GdkModifierType` bitmask** (matching `KeyEventMapping.swift` on the app
  side), decoded to Clutter keyvals via
  `ShellHelperService.MODIFIER_KEYVAL_NAMES_BY_MASK` — only Shift/Control/
  Alt/Super are mapped (the modifiers a paste chord plausibly uses); an
  unrecognized bit is silently not synthesized.
- **The client must not trust `Capabilities` alone** for the hotkey tier.
  `_tryEnable('hotkeys', …)` grabs the real mutter keybinding independently
  of whether the method table actually dispatches, so a broken service can
  still advertise `"hotkeys"`. `ShellHelperClient.probeLiveDispatch()`
  (Swift side) calls `GetPointer` directly — bypassing its own capability
  gate on purpose — and requires a real, correctly-shaped reply before
  `HotkeyBackendResolver` will select `.shellExtensionKeybinding`.
- **`PlaceWindow`/`UnplaceWindow`'s `window_token` argument is a stable
  ROLE string** (currently only `'picker'`), not a window title and not a
  per-invocation UUID. `Placement` (`src/core/placement.js`) identifies its
  own windows by `WM_CLASS === 'clipnest'` (real on both X11 and Wayland
  now that the app calls `g_set_prgname` before `gtk_init()`) plus a fixed,
  per-role title (`ROLE_TITLES`, e.g. `'Clipnest'` for `'picker'`) — never
  by matching the token directly against a window's title. This is also
  why the picker's Alt-Tab/screen-reader-visible title is a real word
  ("Clipnest") rather than a GUID.

**Verification status — read before assuming this has run for real.** GNOME
Shell needs systemd/logind and cannot run in a container, so no method here
has ever been dispatched by a real GNOME Shell or exercised the real
`Meta`/`Shell`/`Clutter`/`Main` namespaces, and this remains true after the
T-P10G/T-RT3 fixes below. What *was* verified, against a real (non-Mutter)
session bus with independent OS processes standing in for the shell and the
app: every method dispatches under its declared name with correctly-shaped
arguments/replies, sender checking accepts the `app.clipnest.Clipnest`
owner and rejects everyone else with a prompt `AccessDenied` (not a hang),
`ReadClipboard`/`SetClipboard` carry a real fd across the wire via
`SCM_RIGHTS`, and `ShortcutActivated`/`ClipboardChanged` signals are
emitted and received with the correct payload shape.

A second, separate harness re-verified `ReadClipboard` and
`PlaceWindow`/`UnplaceWindow` specifically, wiring in the REAL
`clipboard.js`/`placement.js` (not stubs) behind the real `service.js` —
proving the actual fixed `readToFd()` (the `Gio.Socket`-pair pipe
substitute) and the actual fixed wm_class+role window matching both
dispatch correctly end to end over a real D-Bus wire, including a same-
titled-but-wrong-WM_CLASS "impostor" window correctly failing to match.
`Meta`, `Shell`, `Clutter`, `Main`, and window objects were still faked in
both harnesses (a live Mutter compositor cannot run in a container) — their
actual behavior, and everything about real window mapping/first-frame
timing, is still unverified.

## Build

    ./build.sh

Installed per-user by the app (not by the .deb) so it can pick the right
variant at runtime and survive app upgrades without root.

## Tests (`test/`)

Real-gjs tests for `src/core/`, matching its "unit-testable under a bare
gjs" design (each file imports nothing; every GI namespace is injected).
There is no macOS `gjs`; run these on Linux with `gjs` installed
(`apt install gjs` gets you a real one — Ubuntu 22.04/24.04/25.04 track
gjs 1.72/1.80/1.82 respectively, i.e. roughly Shell 42/46/48):

    mkdir -p test/core && cp src/core/*.js test/core/   # test/core/ is gitignored scratch
    cd test && gjs placement.test.js && gjs clipboard.readtofd.test.js

- `placement.test.js` — pure logic over injected fake `Meta`/`global`
  objects (no real GI needed): wm_class+role window matching, the
  queue-on-`window-created`-apply-on-`first-frame` path, and that a
  same-titled window from a different WM_CLASS never gets placed.
- `clipboard.readtofd.test.js` — real `imports.gi.GLib`/`imports.gi.Gio`
  (only `Meta.Selection` is faked), proving `readToFd()`'s `Gio.Socket`
  pipe substitute moves real bytes end to end and that `stop()` actually
  closes what it's holding.

Both exit non-zero on any failure, so `&&`-chaining them is a real gate.
