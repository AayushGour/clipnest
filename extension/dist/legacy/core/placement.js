'use strict';
// Window placement, pointer, and focused-app identity.
//
// This module is the entire reason the extension exists. A Wayland client
// cannot position its own window or query the global pointer, and GNOME has no
// layer-shell — so without this, the picker opens centred on the pointer's
// monitor instead of at the cursor, and cannot sit above a fullscreen window.

// Window identity contract with the app side (T-RT3): every Clipnest toplevel
// sets WM_CLASS to this (the app calls `g_set_prgname` before `gtk_init()`,
// giving every window a real, non-empty WM_CLASS on both X11 and Wayland —
// previously "", ""), and each role gets one fixed, human/screen-reader
// readable title, never a per-invocation UUID. `PlaceWindow`/`UnplaceWindow`'s
// `window_token` D-Bus argument is one of this map's keys (a stable role
// string, e.g. `'picker'`), not a title.
const OUR_WM_CLASS = 'clipnest';
const ROLE_TITLES = Object.freeze({ picker: 'Clipnest' });
const TITLE_ROLES = Object.freeze(
  Object.fromEntries(Object.entries(ROLE_TITLES).map(([role, title]) => [title, role])));

var Placement = class Placement {
  constructor(deps) {
    this._d = deps;
    this._pending = new Map();   // token -> {x, y, flags}
    this._ids = [];
  }

  start() {
    const { global } = this._d;
    // A window may not be mapped when PlaceWindow arrives, so queue by token
    // and apply on first-frame — placing before the first frame is what avoids
    // a visible flash at the wrong position.
    this._ids.push(global.display.connect('window-created', (_d, win) => {
      const actor = win.get_compositor_private();
      if (!actor) return;
      const id = actor.connect('first-frame', () => {
        actor.disconnect(id);
        this._applyPending(win);
      });
    }));
  }

  stop() {
    for (const id of this._ids) {
      try { this._d.global.display.disconnect(id); } catch (e) { /* gone */ }
    }
    this._ids = [];
    this._pending.clear();
  }

  _allWindows() {
    return this._d.global.get_window_actors()
      .map(a => a.meta_window)
      .filter(w => w != null);
  }

  /// Windows are now identified by WM_CLASS rather than
  /// `get_gtk_application_id()`: the latter only ever worked on native
  /// Wayland windows (GTK4 sends it over the Wayland-only gtk_shell1
  /// protocol, which mutter has nothing to forward on X11), while WM_CLASS
  /// is real on both backends now that the app sets `g_set_prgname` before
  /// `gtk_init()` — see the module header comment.
  _ourWindows() {
    return this._allWindows().filter(w => w.get_wm_class() === OUR_WM_CLASS);
  }

  /// Resolves `FocusAndSendKeyChord`'s `window_serial` argument — Mutter's
  /// own `get_stable_sequence()`, a per-process-lifetime unique id ANY
  /// window has (not just this app's own), which is what makes
  /// `FocusAndSendKeyChord` usable against the app the user is pasting
  /// INTO rather than only Clipnest's own windows (contrast `_findByToken`,
  /// which is `PlaceWindow`'s own-window-only lookup). `serial` is coerced
  /// with `Number()` because GJS's `t` (uint64) unpacking can hand back a
  /// BigInt depending on version, while `get_stable_sequence()` always
  /// returns a plain Number.
  findWindowBySerial(serial) {
    const target = Number(serial);
    return this._allWindows().find(w => w.get_stable_sequence() === target) || null;
  }

  /// `token` is a role string (see `ROLE_TITLES`), not a title — the
  /// picker's user-visible title is the fixed string `'Clipnest'` (an app
  /// with a title that happens to also be Alt-Tab/screen-reader announced
  /// sanely), so this resolves the role to its known title before matching.
  /// An unrecognized role (not in `ROLE_TITLES`) never matches anything.
  _findByToken(token) {
    const title = ROLE_TITLES[token];
    if (!title) return null;
    return this._ourWindows().find(w => w.get_title() === title) || null;
  }

  _applyPending(win) {
    if (win.get_wm_class() !== OUR_WM_CLASS) return;
    const token = TITLE_ROLES[win.get_title()];
    if (!token) return;
    const req = this._pending.get(token);
    if (!req) return;
    this._pending.delete(token);
    this._place(win, req);
  }

  /// Clamps `(x, y)` (for a window of `width`x`height`) into the monitor
  /// work area the point falls in before ever calling `move_frame` — a
  /// real, reported bug (`packaging/linux/gnome-shell-test/README.md`'s
  /// "Findings"): placed at the raw cursor position with no clamp, the
  /// picker's height/width could run past the screen edge (e.g. y=600 on
  /// a 900px-tall monitor with the picker's 420px height). The clamp
  /// formula itself is a direct, deliberate PORT of
  /// `WindowPlacement.clampedOrigin` (`Sources/ClipnestViewModels/UI/
  /// Picker/WindowPlacement.swift`, the ~16-test-covered macOS/Linux
  /// SHARED placement math `PickerPanel` already calls on macOS via
  /// `NSScreen.visibleFrame`) — not a new design. That Swift type cannot
  /// run here: a Wayland client can't query its own on-screen position or
  /// the monitor work area, which is this whole extension's reason to
  /// exist (see this file's header comment), so the identical min/max
  /// formula is duplicated here in JS rather than shared across the
  /// language boundary, mirroring how this same file already mirrors
  /// Swift-side constants (e.g. `flags & 1` above documented as "==
  /// NSWindow level .popUpMenu"). Kept as a plain, dependency-free
  /// function (no `this`/`Meta`/`global`) so it's directly unit-tested
  /// under a bare `gjs`, same as the rest of this module's pure logic —
  /// see `placement.test.js`.
  _clampOrigin(x, y, width, height, workArea) {
    const maxX = Math.max(workArea.x + workArea.width - width, workArea.x);
    const maxY = Math.max(workArea.y + workArea.height - height, workArea.y);
    return [
      Math.min(Math.max(x, workArea.x), maxX),
      Math.min(Math.max(y, workArea.y), maxY),
    ];
  }

  _place(win, { x, y, flags }) {
    // The monitor the TARGET point falls in, not whichever monitor the
    // window currently happens to occupy (its pre-move position, possibly
    // still the default GTK placement or a prior show) — mirrors
    // `getPointer()`'s own `get_monitor_index_for_rect` use immediately
    // below for the identical reason: the point being placed at is the
    // authority on which monitor's work area applies, not the window's
    // stale current position.
    const monitor = this._d.global.display.get_monitor_index_for_rect(
      new this._d.Meta.Rectangle({ x, y, width: 1, height: 1 }));
    const [wx, wy, wwidth, wheight] = this.getMonitorWorkArea(monitor);
    // `get_frame_rect()`, not a hardcoded picker size: this module places
    // any Clipnest toplevel by token (today just `'picker'`), and the
    // window's REAL on-screen size (GTK4 can grow a window past its
    // `gtk_window_set_default_size` request to fit its content's natural
    // size) is what actually needs to fit, not an assumed constant.
    const frame = win.get_frame_rect();
    const [clampedX, clampedY] = this._clampOrigin(
      x, y, frame.width, frame.height, { x: wx, y: wy, width: wwidth, height: wheight });
    win.move_frame(true, clampedX, clampedY);  // user_op = true: honoured unconditionally
    if (flags & 1) win.make_above();     // == NSWindow level .popUpMenu
    if (flags & 2) win.stick();          // == .canJoinAllSpaces
    return true;
  }

  placeWindow(token, x, y, flags) {
    const win = this._findByToken(token);
    if (!win) {
      this._pending.set(token, { x, y, flags });
      return false;   // queued; applied on first-frame
    }
    return this._place(win, { x, y, flags });
  }

  unplaceWindow(token) { this._pending.delete(token); }

  getPointer() {
    const [x, y] = this._d.global.get_pointer();
    const monitor = this._d.global.display.get_monitor_index_for_rect(
      new this._d.Meta.Rectangle({ x, y, width: 1, height: 1 }));
    return [x, y, monitor];
  }

  getMonitorWorkArea(monitor) {
    const ws = this._d.global.workspace_manager.get_active_workspace();
    const r = ws.get_work_area_for_monitor(monitor);
    return [r.x, r.y, r.width, r.height];
  }

  /// Focused-app identity, which is the OTHER thing the extension uniquely
  /// provides: on Wayland without it, mutter reports its no_focus_window
  /// sentinel for native Wayland apps, so app-based privacy exclusions cannot
  /// work at all.
  getFocusedApp() {
    const { Shell, global } = this._d;
    const info = {};
    const win = global.display.focus_window;
    const app = Shell.WindowTracker.get_default().focus_app;
    if (app) {
      info['app-id'] = app.get_id().replace(/\.desktop$/, '');
      info['name'] = app.get_name();
    }
    if (win) {
      info['wm-class'] = win.get_wm_class() || '';
      info['pid'] = win.get_pid();
      // The id `FocusAndSendKeyChord`'s `window_serial` argument expects —
      // see `findWindowBySerial`'s doc comment.
      info['window-serial'] = win.get_stable_sequence();
      info['client-type'] =
        win.get_client_type() === this._d.Meta.WindowClientType.WAYLAND ? 'wayland' : 'x11';
      const sandboxed = win.get_sandboxed_app_id();
      if (sandboxed) info['sandboxed-app-id'] = sandboxed;
    }
    return info;
  }
};
