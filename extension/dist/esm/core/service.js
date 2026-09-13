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
//
// EVERY exported D-Bus member below is implemented with the `NameAsync`
// suffix, even the ones that do no actual async work. This isn't cosmetic:
// GJS's `Gio.DBusExportedObject` dispatcher (`_handleMethodCall` in
// `modules/core/overrides/Gio.js`) only ever hands the `invocation` object
// — the one thing `_checkSender` needs — to a method found under that
// suffix; a plain synchronous `MethodName(...)` never sees it at all. So
// the `Async` suffix here means "needs the invocation to sender-check and
// reply", not "does async I/O" (`SetClipboardAsync` is the one member where
// both happen to be true at once). Each method sender-checks first via
// `_checkSender(invocation)` and returns early on failure (which has
// already sent the ACCESS_DENIED reply); everything past that point either
// calls `invocation.return_value(...)`/`return_value_with_unix_fd_list(...)`
// itself, or — for anything that throws before doing so — relies on
// `_handleMethodCall`'s own catch turning the exception into a proper D-Bus
// error reply (true for every synchronous throw here; `SetClipboardAsync`'s
// completion callback is the one place that can run AFTER that catch has
// already returned, so it catches and replies for itself).
var ShellHelperService = class ShellHelperService {
  static PROTOCOL_VERSION = 1;
  static BUS_NAME = 'app.clipnest.ShellHelper';
  static OBJECT_PATH = '/app/clipnest/ShellHelper';
  static APP_BUS_NAME = 'app.clipnest.Clipnest';

  // GdkModifierType bit values (stable X11/GDK ABI, gdk/gdkenums.h) that
  // `SendKeyChord`/`FocusAndSendKeyChord`'s `modifiers: u` argument carries
  // — see `KeyEventMapping.swift`'s identical doc comment on the app's side
  // of this same wire contract. Only the four modifiers a paste chord
  // plausibly uses are mapped to a Clutter keyval; an unset/unrecognized
  // bit is simply not synthesized rather than treated as an error, matching
  // this file's "degrade a feature, don't fail the whole call" ethos.
  static MODIFIER_KEYVAL_NAMES_BY_MASK = [
    [1 << 0, 'Shift_L'],
    [1 << 2, 'Control_L'],
    [1 << 3, 'Alt_L'],
    [1 << 26, 'Super_L'],
  ];

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

    // Best-effort: a client that raced connecting to the signal before
    // `enable()` finished simply reads `Capabilities` directly instead.
    this._emitCapabilitiesChanged();
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

  /// Replies with a value packed against `signature` (the FULL reply
  /// tuple, e.g. `'(b)'`/`'(iii)'` — not a single out-arg's own type), so
  /// every call site matches the contract XML's out-arg list directly.
  _reply(invocation, signature, values) {
    invocation.return_value(new this._d.GLib.Variant(signature, values));
  }

  _replyVoid(invocation) {
    invocation.return_value(null);
  }

  /// Boxes a plain JS object's values into `a{sv}`-ready `GLib.Variant`
  /// instances. Load-bearing, not cosmetic: `new GLib.Variant('a{sv}', obj)`
  /// does NOT auto-convert a dict's VALUES the way a top-level method
  /// return does — verified directly under `gjs` while building this file,
  /// since the "primitives auto-box" claim floating around GJS docs/examples
  /// turned out to only cover already-`GLib.Variant`-wrapped dict values.
  /// Passing a raw string/number/boolean here throws
  /// "Expected an object of type GVariant ... but got type string" at
  /// `emit_signal`/`return_value` time. Whole-number values that fit in
  /// `i` (`pid`, `window-serial`, ...) pack as int32; anything else numeric
  /// packs as a double rather than silently truncating. An unrecognized
  /// value shape is dropped, not thrown — one bad field must not take the
  /// whole reply/signal down.
  _variantDict(obj) {
    const { GLib } = this._d;
    const out = {};
    for (const [key, value] of Object.entries(obj)) {
      if (typeof value === 'string') out[key] = GLib.Variant.new_string(value);
      else if (typeof value === 'boolean') out[key] = GLib.Variant.new_boolean(value);
      else if (typeof value === 'number') {
        out[key] =
          Number.isInteger(value) && Math.abs(value) < 2 ** 31
            ? GLib.Variant.new_int32(value)
            : GLib.Variant.new_double(value);
      }
    }
    return out;
  }

  /// `SendKeyChord`/`FocusAndSendKeyChord`'s `modifiers: u` bitmask ->
  /// the Clutter keyvals `InputSynthesizer.sendChord` needs to actually
  /// press/release. See `MODIFIER_KEYVAL_NAMES_BY_MASK`'s doc comment.
  _modifierKeyvals(mask) {
    const { Clutter } = this._d;
    const keyvals = [];
    for (const [bit, name] of ShellHelperService.MODIFIER_KEYVAL_NAMES_BY_MASK) {
      if (mask & bit) keyvals.push(Clutter[`KEY_${name}`]);
    }
    return keyvals;
  }

  _emitCapabilitiesChanged() {
    if (!this._impl) return;
    try {
      this._impl.emit_signal(
        'CapabilitiesChanged', new this._d.GLib.Variant('(as)', [this._capabilities]));
    } catch (e) { logError(e, 'clipnest: failed to emit CapabilitiesChanged'); }
  }

  /// Wired as `ClipboardWatcher`'s `onChanged` callback by the entry point
  /// (see `entry-esm.js`/`entry-legacy.js`) — NOT called directly by
  /// anything in this file. `source` is currently always an empty
  /// `a{sv}` (the contract reserves the field; this service has no
  /// additional per-change metadata to offer yet — see
  /// `ShellHelperResponses.parseClipboardChanged`'s doc comment on the
  /// app side for why that's fine, it never reads `source`'s contents).
  notifyClipboardChanged(selectionType, serial, mimetypes, ownerIsUs) {
    if (!this._impl) return;
    try {
      this._impl.emit_signal(
        'ClipboardChanged',
        new this._d.GLib.Variant(
          '(utasba{sv})',
          [selectionType, serial, mimetypes, ownerIsUs, this._variantDict({})]));
    } catch (e) { logError(e, 'clipnest: failed to emit ClipboardChanged'); }
  }

  /// Wired as `Keybindings`' `onActivated` callback by the entry point.
  /// Pointer/focus lookups are individually best-effort — a monitor
  /// misdetection must not suppress the shortcut firing at all.
  notifyShortcutActivated(action) {
    if (!this._impl) return;
    try {
      const { global } = this._d;
      let pointerX = 0, pointerY = 0, monitor = -1;
      try { [pointerX, pointerY, monitor] = this._m.placement.getPointer(); } catch (e) {}
      let focus = {};
      try { focus = this._m.placement.getFocusedApp(); } catch (e) {}
      this._impl.emit_signal(
        'ShortcutActivated',
        new this._d.GLib.Variant(
          '(suiiia{sv})',
          [
            action, global.get_current_time(), pointerX, pointerY, monitor,
            this._variantDict(focus),
          ]));
    } catch (e) { logError(e, 'clipnest: failed to emit ShortcutActivated'); }
  }

  // --- properties ---
  get ProtocolVersion() { return ShellHelperService.PROTOCOL_VERSION; }
  get ShellVersion() { return this._d.Main.shellVersion ?? ''; }
  get Capabilities() { return this._capabilities; }

  // --- methods (declared in ../../dbus/app.clipnest.ShellHelper1.xml) ---

  SetClipboardWatchAsync([enable, includePrimary], invocation) {
    if (!this._checkSender(invocation)) return;
    // Always stop first: `ClipboardWatcher.start()` is a no-op while
    // already watching, so toggling `include_primary` alone would
    // otherwise silently not take effect.
    this._m.clipboard.stop();
    if (enable) this._m.clipboard.start(includePrimary);
    this._replyVoid(invocation);
  }

  GetClipboardMimeTypesAsync([selection], invocation) {
    if (!this._checkSender(invocation)) return;
    const mimetypes = this._m.clipboard.getMimeTypes(selection);
    this._reply(invocation, '(ast)', [mimetypes, this._m.clipboard.serial]);
  }

  ReadClipboardAsync([selection, mimetype], invocation) {
    if (!this._checkSender(invocation)) return;
    const { Gio } = this._d;
    const fd = this._m.clipboard.readToFd(selection, mimetype);
    invocation.return_value_with_unix_fd_list(
      new this._d.GLib.Variant('(h)', [0]), Gio.UnixFDList.new_from_array([fd]));
  }

  /// The one member that is genuinely asynchronous, not just
  /// invocation-needing: the incoming fd is drained via `splice_async`
  /// (never a blocking read loop — see `../../dbus/app.clipnest.ShellHelper1.xml`'s
  /// own header comment on why bulk transfers are fds at all: buffering the
  /// full payload before `Meta.SelectionSourceMemory` can take ownership is
  /// unavoidable, but BLOCKING the compositor's main loop while doing so is
  /// not). Runs entirely after `_handleMethodCall`'s own try/catch has
  /// already returned, so — unlike every other member here — it must catch
  /// and reply for itself on failure rather than letting an exception
  /// propagate into a caught-for-free D-Bus error reply.
  SetClipboardAsync([mimetype, fdIndex], invocation, fdList) {
    if (!this._checkSender(invocation)) return;
    const { Gio, GLib } = this._d;
    let inStream;
    try {
      inStream = new Gio.UnixInputStream({ fd: fdList.get(fdIndex), close_fd: true });
    } catch (e) {
      invocation.return_dbus_error('org.gnome.gjs.JSError.ValueError', String(e));
      return;
    }
    const outStream = Gio.MemoryOutputStream.new_resizable();
    outStream.splice_async(
      inStream,
      Gio.OutputStreamSpliceFlags.CLOSE_SOURCE | Gio.OutputStreamSpliceFlags.CLOSE_TARGET,
      GLib.PRIORITY_DEFAULT, null,
      (stream, result) => {
        try {
          stream.splice_finish(result);
          const bytes = stream.steal_as_bytes();
          const serial = this._m.clipboard.setClipboard(mimetype, bytes.toArray());
          invocation.return_value(new GLib.Variant('(t)', [serial]));
        } catch (e) {
          logError(e, 'clipnest: SetClipboard failed');
          try {
            invocation.return_dbus_error('org.gnome.gjs.JSError.ValueError', String(e));
          } catch (e2) { /* invocation already answered */ }
        }
      });
  }

  SendKeyChordAsync([keyval, modifiers], invocation) {
    if (!this._checkSender(invocation)) return;
    const ok = this._m.input.sendChord(keyval, this._modifierKeyvals(modifiers));
    this._reply(invocation, '(b)', [ok]);
  }

  FocusAndSendKeyChordAsync([windowSerial, keyval, modifiers], invocation) {
    if (!this._checkSender(invocation)) return;
    const win = this._m.placement.findWindowBySerial(windowSerial);
    const result = this._m.input.focusAndSendChord(win, keyval, this._modifierKeyvals(modifiers));
    this._reply(invocation, '(s)', [result]);
  }

  GetFocusedAppAsync(_args, invocation) {
    if (!this._checkSender(invocation)) return;
    this._reply(invocation, '(a{sv})', [this._variantDict(this._m.placement.getFocusedApp())]);
  }

  GetPointerAsync(_args, invocation) {
    if (!this._checkSender(invocation)) return;
    const [x, y, monitor] = this._m.placement.getPointer();
    this._reply(invocation, '(iii)', [x, y, monitor]);
  }

  GetMonitorWorkAreaAsync([monitor], invocation) {
    if (!this._checkSender(invocation)) return;
    const rect = this._m.placement.getMonitorWorkArea(monitor);
    this._reply(invocation, '((iiii))', [rect]);
  }

  PlaceWindowAsync([windowToken, x, y, flags], invocation) {
    if (!this._checkSender(invocation)) return;
    const ok = this._m.placement.placeWindow(windowToken, x, y, flags);
    this._reply(invocation, '(b)', [ok]);
  }

  UnplaceWindowAsync([windowToken], invocation) {
    if (!this._checkSender(invocation)) return;
    this._m.placement.unplaceWindow(windowToken);
    this._replyVoid(invocation);
  }
};

// Appended by build.sh for the esm variant only -- see this file's
// header comment. src/core/service.js is unmodified; legacy's var globals are
// untouched.
export { ShellHelperService };
