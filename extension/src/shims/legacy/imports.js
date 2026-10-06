'use strict';
// Shim for GNOME Shell 42-44 (pre-ESM). Loaded by entry-legacy.js.
//
// GJS < 1.76 cannot PARSE `import x from 'gi://X'` — it is a syntax error, not
// a runtime failure — so one file genuinely cannot serve both worlds. Only the
// two shims differ; everything in ../core/ is shared verbatim and receives
// these namespaces by injection.
const { Clutter, Gio, GLib, Meta, Shell, St } = imports.gi;
const Main = imports.ui.main;

var deps = {
  Clutter, Gio, GLib, Meta, Shell, St, Main,
  get global() { return global; },
  // Meta.later_add moved to global.compositor.get_laters().add() in Shell 44.
  // This is the ONLY non-ESM API break across 42 -> 50 among everything the
  // extension uses; Main.wm.addKeybinding, global.display.focus_window,
  // global.get_pointer, seat.create_virtual_device + notify_keyval,
  // Meta.Selection.*, Meta.Window.{move_frame,make_above,get_wm_class,get_pid}
  // and Shell.WindowTracker.focus_app are all identical on 42, 46 and 50.
  laterAdd: (type, fn) => Meta.later_add(type, fn),
  laterRemove: (id) => Meta.later_remove(id),
};
