# Clipnest GNOME Shell extension

Optional. Clipnest works without it — but on a Wayland session it supplies the
capabilities a Wayland client structurally cannot have on its own.

## Why it exists

| Capability | Without the extension | With it |
|---|---|---|
| Reading the clipboard while unfocused | Works, via mutter's XWayland selection bridge | Works, natively |
| **Writing** the clipboard while unfocused | **Silently does NOT work** — GDK's Wayland clipboard write (`gdk_clipboard_set_text`/`gdk_wayland_device_set_selection`) needs a fresh input-event serial from Clipnest's own `GdkWaylandSeat`, which a background process reacting to a global hotkey never has; the compositor drops the request with no error at all (confirmed live, T-SNIPPET-FF1 — this is why snippet expansion's clipboard-fallback tier silently did nothing in Firefox) | Works, via the privileged `Meta.Selection.set_owner` this extension's `ClipboardWatcher.setClipboard` exposes (`SetClipboard` D-Bus method, wired to `LinuxClipboardSelectionReplacer.privilegedTextWriter`) |
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

`src/core/*.js` is also written with **zero exports** (legacy style: `var X =
class X {...}`), since legacy's `Me.imports.core.x` resolves those as plain
`var` globals with no export needed. Shell 45+ is real ESM, though, and
`entry-esm.js` does `import { X } from './core/x.js'`, which needs a genuine
named export — one that nothing supplied until `build.sh` was fixed for
**T-EXT-ESM-BROKEN1** (`gnome-extensions enable` failed on every Shell 45+,
i.e. all current Ubuntu including 24.04, with `SyntaxError: ambiguous
indirect export`). The fix: `build.sh` mechanically scans each top-level `var
NAME = ...` in the copy it places under `dist/esm/core/` and appends a
trailing `export { NAME, ... };` line — additive only, applied only to that
copy. `dist/legacy` and `src/core/*.js` itself are never touched, so
`src/core/*.js` stays the one source of truth this section already promised;
see `build.sh`'s own header comment for the full rationale.

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

**Verification status — read before assuming this has run for real.**
**UPDATE 2026-09-13 (T-EXT-ESM-BROKEN1): the claim below that "no method
here has ever been dispatched by a real GNOME Shell" is FALSE and stale —
corrected here, not left for a follow-up, per this repo's own doc-currency
rule.** Two independent things now run this against a REAL, live Mutter:
`packaging/linux/gnome-shell-test/` (systemd-in-Docker, both a Shell 42
jammy leg and — new this task — a Shell 46 noble leg,
`run-noble-esm-test.sh`) and a real Ubuntu 24.04/GNOME 46 VM, driven end to
end for the first time in this port's history:

- The `esm` variant (previously broken for its entire history — see
  `build.sh`'s header comment and `Layout` above) reaches
  `gnome-extensions info` `State: ACTIVE` with an empty error string, and
  `Capabilities` correctly lists all 6 (`clipboard, paste, pointer,
  placement, focus, hotkeys`) — live D-Bus `GetExtensionInfo`/property
  reads against the real running `org.gnome.Shell`, not a stub.
- `clipnest`'s own `HotkeyBackendResolver` live-upgraded from
  `.gsettingsFloor` to `.shellExtensionKeybinding` within its normal
  startup retry window once the extension came up — the app-side signal
  that it actually detected and trusts the now-loading extension.
- The AT-SPI/GTK4 snippet-expansion tier was re-verified end to end against
  a real `gnome-text-editor`, with an **exact-match** assertion (not
  "contains") on both a direct AT-SPI buffer read and the saved file:
  keyword `test` → body `this is testing`, byte for byte. See
  `extension/test/build.esm-exports.test.sh` and
  `packaging/linux/gnome-shell-test/run-noble-esm-test.sh`'s own header for
  the negative-control proof that this same harness FAILS (reproduces the
  exact live SyntaxError) against the original zero-export code.
- **UPDATE 2026-09-13 (T-SHELLHELPER-TIMEOUT1): now working end to end, and
  NOT an extension bug either time.** The line immediately below this one
  described T-SNIPPET-FF1's fix as "not yet working" and blamed a "596ms and
  613ms" `SetClipboard` measurement on `ShellHelperClient`'s 250ms default
  call timeout. That number was real but mis-attributed: it was
  `LinuxClipboardSelectionReplacer`'s own separate ~500ms `waitForChange`
  polling ceiling firing (because the write never reached the wire at all),
  not `SetClipboard`'s own round trip. The actual defect was on the Swift
  side, in `Sources/ClipnestLinuxAppKit/DBus/ClipnestControlService.swift`:
  its `DBusCalling` conformance never implemented the fd-attaching call
  overload `SetClipboard`/`ReadClipboard` need, so it silently fell through
  to that protocol's "unsupported" `nil` default — the call never sent a
  single byte, regardless of any timeout value. Fixed by implementing that
  overload (reusing the same serial-correlation machinery the working
  non-fd overload already had) and giving `SetClipboard` specifically its
  own, measurement-derived timeout (`ShellHelperClient
  .defaultClipboardWriteTimeout`, 1000ms — real round trips on this VM
  measured 2–70ms across 19 trials once the call genuinely reached the
  extension). Re-verified against the same real GNOME 46 VM: `Capabilities`
  includes `clipboard`, `SetClipboard` gets a real reply every time
  (`gotReply=true`, 2–70ms), and the Firefox exact-match test (URL bar
  keyword `test` → body `this is testing`) passes byte for byte. Full
  measurement writeup: `Sources/ClipnestLinuxAppKit/DBus/ShellHelperClient
  .swift`'s `defaultClipboardWriteTimeout` doc comment and
  `.claude/logs/senior-dev.md`.

**Everything below this point describes verification status BEFORE
2026-09-13** (a real (non-Mutter) session bus with independent OS processes
standing in for the shell and the app): every method dispatches under its
declared name with correctly-shaped arguments/replies, sender checking
accepts the `app.clipnest.Clipnest` owner and rejects everyone else with a
prompt `AccessDenied` (not a hang), `ReadClipboard`/`SetClipboard` carry a
real fd across the wire via `SCM_RIGHTS`, and `ShortcutActivated`/
`ClipboardChanged` signals are emitted and received with the correct
payload shape.

A second, separate harness re-verified `ReadClipboard` and
`PlaceWindow`/`UnplaceWindow` specifically, wiring in the REAL
`clipboard.js`/`placement.js` (not stubs) behind the real `service.js` —
proving the actual fixed `readToFd()` (the `Gio.Socket`-pair pipe
substitute) and the actual fixed wm_class+role window matching both
dispatch correctly end to end over a real D-Bus wire, including a same-
titled-but-wrong-WM_CLASS "impostor" window correctly failing to match.
`Meta`, `Shell`, `Clutter`, `Main`, and window objects were still faked in
both harnesses (a live Mutter compositor cannot run in a container — true
when written, since corrected: see the 2026-09-13 update above) — real
window mapping/first-frame timing against a live Mutter is now covered by
the placement re-verification logged in
`packaging/linux/gnome-shell-test/README.md`'s own Update sections.

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
- `build.esm-exports.test.sh` — plain bash, no `gjs`/Docker needed, runs
  anywhere (including macOS): mechanically confirms every `src/core/*.js`
  top-level `var NAME` gets a matching `export` in the generated
  `dist/esm/core/*.js`, that `dist/legacy` stays byte-identical to
  `src/core/*.js`, that `src/core/*.js` itself never gains an export, and
  that every `entry-esm.js` import from `./core/` actually resolves to one
  — the T-EXT-ESM-BROKEN1 regression class (a generated file silently
  missing an export).

Both `.test.js` files exit non-zero on any failure, so `&&`-chaining them is
a real gate; `build.esm-exports.test.sh` does the same for the ESM export
step. The full end-to-end proof that the `esm` variant actually loads on a
real Shell 45+ compositor is
`packaging/linux/gnome-shell-test/run-noble-esm-test.sh` (needs Docker, not
`gjs`) — see that directory's README.md.
