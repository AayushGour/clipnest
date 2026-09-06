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
    // See readToFd()'s doc comment: each pending read owns a Gio.Socket
    // (the local end of a pipe substitute) that this class must close
    // itself, on its own schedule — the fd actually handed out over D-Bus
    // is an independent duplicate, never this socket's own fd.
    this._pendingReadSockets = new Set();
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
      // A source that dies between the signal and this call is normal, not
      // exceptional — the copy is simply lost, same as X11 semantics; see
      // getMimeTypes()'s own doc comment.
      const mimetypes = this.getMimeTypes(type);
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
    for (const s of this._pendingReadSockets) {
      try { s.close(); } catch (e) { /* already gone */ }
    }
    this._pendingReadSockets.clear();
  }

  /// Live query for `GetClipboardMimeTypes` — the mimetypes currently on
  /// offer for `selectionType`, independent of whether `start()` has ever
  /// been called (a caller may want this once, without paying for an
  /// ongoing watch). Returns `[]` rather than throwing when the current
  /// source dies between the query and the read — the copy is simply lost,
  /// same as X11 semantics, not a real failure this caller can act on.
  getMimeTypes(selectionType) {
    const sel = this._d.global.display.get_selection();
    try {
      return sel.get_mimetypes(selectionType) || [];
    } catch (e) {
      return [];
    }
  }

  /// Builds a real pipe substitute: two connected `Gio.Socket`s, returned as
  /// `[serverEnd, clientEnd]`. `readToFd()` writes into `serverEnd` and hands
  /// `clientEnd`'s raw fd to the D-Bus caller, exactly the roles a pipe's
  /// write/read ends would play.
  ///
  /// This exists because `GLib.unix_open_pipe`/`GLibUnix.open_pipe` — the
  /// documented way to get an anonymous pipe from GJS — is not safe to call
  /// from JS at all, on ANY gjs version this extension supports. Verified
  /// directly under real `gjs`, not assumed from docs (the same discipline
  /// that caught the `a{sv}` boxing bug in this codebase):
  ///   - gjs 1.72 (~Shell 42): `GLib.unix_open_pipe(flags, 0)` (this file's
  ///     old call) throws `GLib.Error g-unix-error-quark: Bad address` —
  ///     i.e. this NEVER worked, on the oldest version supported, not just
  ///     a recent regression.
  ///   - gjs 1.80 (~Shell 46): same "Bad address", from both
  ///     `GLib.unix_open_pipe` and its replacement `GLibUnix.open_pipe` —
  ///     the rename didn't fix the actual bug, which is GJS's marshalling
  ///     of the fixed-size `int fds[2]` (out caller-allocates) parameter.
  ///     Passing an `Int32Array(2)` instead of a plain array avoids the
  ///     exception but silently does NOT write the real fds back (both
  ///     stay 0) — worse than throwing, so it is not a viable workaround.
  ///   - gjs 1.82 (~Shell 48): the old call is now a flat `TypeError`
  ///     (argument shape changed again); `GLibUnix.open_pipe` still throws
  ///     the same "Bad address".
  /// A raw `pipe2()` syscall (checked via Python in the same container)
  /// works fine — this is a GJS/GObject-introspection binding defect, not a
  /// sandboxing or kernel restriction.
  ///
  /// `Gio.Socket`/`Gio.UnixSocketAddress`, by contrast, have no fixed-size
  /// array out-parameters anywhere in this path (`get_fd()` etc. are plain
  /// scalar returns) and are unaffected — verified working, real bytes
  /// end-to-end, on gjs 1.72, 1.80, and 1.82 alike. The loopback socket
  /// briefly touches the filesystem (a `mkstemp`-style 0700 temp
  /// directory), unlike a real pipe, but is unlinked immediately after
  /// `connect()`+`accept()`, and the 0700 directory permission means no
  /// other user can even see the path to race it.
  _makePipeSocketPair() {
    const { GLib, Gio } = this._d;
    const dir = GLib.dir_make_tmp('clipnest-pipe-XXXXXX');
    const path = GLib.build_filenamev([dir, 's']);
    try {
      const listener = Gio.Socket.new(
        Gio.SocketFamily.UNIX, Gio.SocketType.STREAM, Gio.SocketProtocol.DEFAULT);
      const addr = Gio.UnixSocketAddress.new(path);
      listener.bind(addr, false);
      listener.listen();
      const clientEnd = Gio.Socket.new(
        Gio.SocketFamily.UNIX, Gio.SocketType.STREAM, Gio.SocketProtocol.DEFAULT);
      clientEnd.connect(addr, null);
      const serverEnd = listener.accept(null);
      try { listener.close(); } catch (e) { /* already gone */ }
      return [serverEnd, clientEnd];
    } finally {
      try { GLib.unlink(path); } catch (e) { /* best-effort cleanup */ }
      try { GLib.rmdir(dir); } catch (e) { /* best-effort cleanup */ }
    }
  }

  /// Streams the selection into a pipe substitute and returns the READ end
  /// as a UNIX fd. Never buffers the payload in JS — a 20 MB image must not
  /// land on the GJS heap or block the compositor's main loop.
  readToFd(selectionType, mimetype) {
    const [serverEnd, clientEnd] = this._makePipeSocketPair();
    const outConn = serverEnd.connection_factory_create_connection();
    const out = outConn.get_output_stream();
    const sel = this._d.global.display.get_selection();
    sel.transfer_async(selectionType, mimetype, -1, out, null, (s, res) => {
      try { s.transfer_finish(res); } catch (e) { /* reader sees a short read */ }
      // Closing the connection ALSO closes the `serverEnd` socket it wraps
      // (verified directly: `serverEnd.get_fd()` is `-1` immediately after
      // this) — a second explicit `serverEnd.close()` here would be a
      // genuine double-close of the same fd, not a harmless belt-and-
      // suspenders call.
      try { outConn.close(null); } catch (e) { /* already closed */ }
    });

    // Hand out an INDEPENDENT duplicate of `clientEnd`'s fd, not the fd
    // itself. `Gio.UnixFDList.new_from_array()` — what
    // `ShellHelperService.ReadClipboardAsync` uses to build the D-Bus
    // reply — TAKES OWNERSHIP of the fd it's given; unlike `.append()`, it
    // does not dup(). Verified directly: handing it `clientEnd`'s own fd
    // and later letting this class's own cleanup close its `clientEnd`
    // copy produced a real `GLib-CRITICAL **: g_close(fd) failed with
    // EBADF` — two owners racing to close the same fd. A throwaway
    // `Gio.UnixFDList` used purely as a `dup(2)` primitive (`.append()`
    // dups the fd IN, `.get()` dups it back OUT — verified: the two
    // resulting fd numbers differ, and each survives the other being
    // closed) keeps `clientEnd`'s own fd under this class's sole ownership
    // the whole time, so the 30-second cleanup below can never race
    // whatever actually closes the fd that went out over D-Bus.
    const dupList = new this._d.Gio.UnixFDList();
    const rfd = dupList.get(dupList.append(clientEnd.get_fd()));

    this._pendingReadSockets.add(clientEnd);
    this._d.GLib.timeout_add_seconds(this._d.GLib.PRIORITY_DEFAULT, 30, () => {
      this._pendingReadSockets.delete(clientEnd);
      try { clientEnd.close(); } catch (e) { /* already gone */ }
      return this._d.GLib.SOURCE_REMOVE;
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
