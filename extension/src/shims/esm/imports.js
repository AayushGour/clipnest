'use strict';
// Shim for GNOME Shell 45+ (ESM). Loaded by entry-esm.js.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export const deps = {
  Clutter, Gio, GLib, Meta, Shell, St, Main,
  get global() { return globalThis.global; },
  laterAdd: (type, fn) => globalThis.global.compositor.get_laters().add(type, fn),
  laterRemove: (id) => globalThis.global.compositor.get_laters().remove(id),
};
