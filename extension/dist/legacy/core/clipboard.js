'use strict';
// Clipboard watching + transfer, via Meta.Selection.
//
// Dependency-injected: every GI namespace arrives through `deps` so this file
// imports nothing and is unit-testable under a bare `gjs`. That is what lets
// one source tree serve both the pre-45 `imports.gi` world and the 45+ ESM
// world (see ../shims/).
//
// Meta.Selection is used rather than St.Clipboard. St.Clipboard's
// get_content/set_content/get_mimetypes DO handle arbitrary MIME types
// (the "non-text items are not handled" note applies only to get_text/set_text),
// but it offers no change signal and no streaming transfer, so it is strictly
// worse here.
var ClipboardWatcher = class ClipboardWatcher {
  constructor(deps, onChanged) {
    this._d = deps;
    this._onChanged = onChanged;
    this._serial = 0;
    this._ownSource = null;
    this._ids = [];
    this._watching = false;
  }

  get serial() { return this._serial; }

  start(includePrimary) {
    if (this._watching) return;
    const sel = this._d.global.display.get_selection();
    this._ids.push(sel.connect('owner-changed', (_s, type, source) => {
      const Meta = this._d.Meta;
      if (type !== Meta.SelectionType.SELECTION_CLIPBOARD &&
          !(includePrimary && type === Meta.SelectionType.SELECTION_PRIMARY))
        return;
      this._serial += 1;
      // Identity comparison, not content comparison: we know exactly whether
      // this is our own write because we hold the source object we set.
      const ownerIsUs = source !== null && source === this._ownSource;
      let mimetypes = [];
      try {
        mimetypes = sel.get_mimetypes(type) || [];
      } catch (e) {
        // A source that dies between the signal and this call is normal, not
        // exceptional — the copy is simply lost, same as X11 semantics.
        mimetypes = [];
      }
      this._onChanged(type, this._serial, mimetypes, ownerIsUs);
    }));
    this._watching = true;
  }

  stop() {
    const sel = this._d.global.display.get_selection();
    for (const id of this._ids) {
      try { sel.disconnect(id); } catch (e) { /* already gone */ }
    }
    this._ids = [];
    this._watching = false;
  }

  /// Streams the selection into a pipe and returns the READ end as a UNIX fd.
  /// Never buffers the payload in JS — a 20 MB image must not land on the GJS
  /// heap or block the compositor's main loop.
  readToFd(selectionType, mimetype) {
    const { GLib, Gio } = this._d;
    const [ok, rfd, wfd] = GLib.unix_open_pipe(GLib.SPAWN_LEAVE_DESCRIPTORS_OPEN, 0);
    if (!ok) throw new Error('unix_open_pipe failed');
    const out = new Gio.UnixOutputStream({ fd: wfd, close_fd: true });
    const sel = this._d.global.display.get_selection();
    sel.transfer_async(selectionType, mimetype, -1, out, null, (s, res) => {
      try { s.transfer_finish(res); } catch (e) { /* reader sees a short read */ }
      try { out.close(null); } catch (e) { /* already closed */ }
    });
    return rfd;
  }

  /// Takes ownership with `bytes` for `mimetype`.
  ///
  /// Honest limitation: MetaSelectionSourceMemory carries ONE mime type, so the
  /// extension path cannot offer multiple representations simultaneously. The
  /// XWayland path can, which is why it ranks above this one for writes.
  setClipboard(mimetype, bytes) {
    const { Meta, GLib } = this._d;
    const source = Meta.SelectionSourceMemory.new(mimetype, GLib.Bytes.new(bytes));
    this._ownSource = source;
    this._d.global.display.get_selection()
      .set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, source);
    this._serial += 1;
    return this._serial;
  }
};
