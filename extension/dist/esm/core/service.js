'use strict';
// The D-Bus service: wires core modules to app.clipnest.ShellHelper1.
//
// Two properties of this file are load-bearing for "don't break the desktop":
//   1. Every feature module is enabled inside its OWN try/catch, so a module
//      that fails on a future GNOME release drops one Capabilities entry
//      instead of taking clipboard watching down with it.
//   2. Every method is sender-checked. This service can read the clipboard and
//      inject keystrokes; it must not become a capability any app on the
//      session bus can borrow.
var ShellHelperService = class ShellHelperService {
  static PROTOCOL_VERSION = 1;
  static BUS_NAME = 'app.clipnest.ShellHelper';
  static OBJECT_PATH = '/app/clipnest/ShellHelper';
  static APP_BUS_NAME = 'app.clipnest.Clipnest';

  constructor(deps, ifaceXml, modules) {
    this._d = deps;
    this._ifaceXml = ifaceXml;
    this._m = modules;               // {clipboard, input, placement, keybindings}
    this._capabilities = [];
    this._impl = null;
    this._nameId = 0;
    this._appOwner = null;
    this._ownerWatchId = 0;
  }

  get capabilities() { return this._capabilities; }

  enable() {
    const { Gio } = this._d;
    this._impl = Gio.DBusExportedObject.wrapJSObject(this._ifaceXml, this);

    // Per-module enable, so partial breakage degrades instead of failing whole.
    this._tryEnable('clipboard', () => this._m.clipboard.start(false));
    this._tryEnable('paste', () => { /* device is created lazily on first use */ });
    this._tryEnable('pointer', () => { /* stateless */ });
    this._tryEnable('placement', () => this._m.placement.start());
    this._tryEnable('focus', () => { /* stateless */ });
    this._tryEnable('hotkeys', () => this._m.keybindings.start());

    this._impl.export(Gio.DBus.session, ShellHelperService.OBJECT_PATH);
    this._nameId = Gio.bus_own_name(
      Gio.BusType.SESSION, ShellHelperService.BUS_NAME,
      Gio.BusNameOwnerFlags.NONE, null, null, null);

    this._ownerWatchId = Gio.bus_watch_name(
      Gio.BusType.SESSION, ShellHelperService.APP_BUS_NAME,
      Gio.BusNameWatcherFlags.NONE,
      (_c, _n, owner) => { this._appOwner = owner; },
      () => { this._appOwner = null; });
  }

  disable() {
    // Must be idempotent and must never throw — gnome-shell calls this on
    // lock, on unlock, and on uninstall.
    const { Gio } = this._d;
    for (const [name, fn] of [
      ['keybindings', () => this._m.keybindings.stop()],
      ['placement', () => this._m.placement.stop()],
      ['clipboard', () => this._m.clipboard.stop()],
      ['input', () => this._m.input.destroy()],
    ]) {
      try { fn(); } catch (e) { logError(e, `clipnest: ${name} teardown`); }
    }
    if (this._ownerWatchId) { try { Gio.bus_unwatch_name(this._ownerWatchId); } catch (e) {} }
    if (this._nameId) { try { Gio.bus_unown_name(this._nameId); } catch (e) {} }
    if (this._impl) { try { this._impl.unexport(); } catch (e) {} }
    this._ownerWatchId = 0; this._nameId = 0; this._impl = null;
    this._capabilities = [];
  }

  _tryEnable(capability, fn) {
    try {
      fn();
      this._capabilities.push(capability);
    } catch (e) {
      logError(e, `clipnest: capability '${capability}' unavailable on this GNOME version`);
    }
  }

  _checkSender(invocation) {
    // Same shape gnome-shell's own DBusSenderChecker uses for
    // org.gnome.Shell.Introspect: only the process that owns the app's bus
    // name may drive this service.
    const sender = invocation.get_sender();
    if (this._appOwner && sender === this._appOwner) return true;
    invocation.return_error_literal(
      this._d.Gio.DBusError, this._d.Gio.DBusError.ACCESS_DENIED,
      'Only Clipnest may call this service.');
    return false;
  }

  // --- properties ---
  get ProtocolVersion() { return ShellHelperService.PROTOCOL_VERSION; }
  get ShellVersion() { return this._d.Main.shellVersion ?? ''; }
  get Capabilities() { return this._capabilities; }
};
