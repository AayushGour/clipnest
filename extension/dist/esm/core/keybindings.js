'use strict';
// Global shortcuts registered through mutter itself.
//
// Accelerators are NOT part of the D-Bus contract: both the app and this
// extension read the same GSettings schema, so rebinding in Settings is one
// set_strv() and the two can never disagree about the current chord.
var Keybindings = class Keybindings {
  constructor(deps, onActivated) {
    this._d = deps;
    this._onActivated = onActivated;
    this._bound = [];
    this._settings = null;
    this._changedId = 0;
  }

  static ACTIONS = ['toggle-picker', 'expand-snippet'];

  start() {
    const { Gio, Main, Shell, Meta } = this._d;
    this._settings = new Gio.Settings({ schema_id: 'app.clipnest.Clipnest.Keybindings' });
    this._bindAll();
    // Rebinding in the app's Settings writes the schema; re-read and re-grab.
    this._changedId = this._settings.connect('changed', () => {
      this._unbindAll();
      this._bindAll();
    });
  }

  _bindAll() {
    const { Main, Shell, Meta } = this._d;
    for (const action of Keybindings.ACTIONS) {
      Main.wm.addKeybinding(
        action, this._settings,
        Meta.KeyBindingFlags.NONE,
        Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
        () => this._onActivated(action));
      this._bound.push(action);
    }
  }

  _unbindAll() {
    for (const action of this._bound) {
      try { this._d.Main.wm.removeKeybinding(action); } catch (e) { /* not bound */ }
    }
    this._bound = [];
  }

  stop() {
    this._unbindAll();
    if (this._settings && this._changedId) {
      try { this._settings.disconnect(this._changedId); } catch (e) { /* gone */ }
    }
    this._settings = null;
    this._changedId = 0;
  }
};

// Appended by build.sh for the esm variant only -- see this file's
// header comment. src/core/keybindings.js is unmodified; legacy's var globals are
// untouched.
export { Keybindings };
