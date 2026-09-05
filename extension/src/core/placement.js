'use strict';
// Window placement, pointer, and focused-app identity.
//
// This module is the entire reason the extension exists. A Wayland client
// cannot position its own window or query the global pointer, and GNOME has no
// layer-shell — so without this, the picker opens centred on the pointer's
// monitor instead of at the cursor, and cannot sit above a fullscreen window.
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

  _ourWindows() {
    return this._d.global.get_window_actors()
      .map(a => a.meta_window)
      .filter(w => w && w.get_gtk_application_id() === 'app.clipnest.Clipnest');
  }

  _findByToken(token) {
    // The token is the window title, a per-invocation UUID the app sets on its
    // own window. get_gtk_application_id() works on native Wayland windows
    // because GTK4 sends gtk_shell1.set_dbus_properties, which mutter forwards.
    return this._ourWindows().find(w => w.get_title() === token) || null;
  }

  _applyPending(win) {
    const token = win.get_title();
    const req = this._pending.get(token);
    if (!req) return;
    this._pending.delete(token);
    this._place(win, req);
  }

  _place(win, { x, y, flags }) {
    win.move_frame(true, x, y);          // user_op = true: honoured unconditionally
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
      info['client-type'] =
        win.get_client_type() === this._d.Meta.WindowClientType.WAYLAND ? 'wayland' : 'x11';
      const sandboxed = win.get_sandboxed_app_id();
      if (sandboxed) info['sandboxed-app-id'] = sandboxed;
    }
    return info;
  }
};
