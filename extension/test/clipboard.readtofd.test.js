'use strict';
// Real-gjs test for ClipboardWatcher.readToFd() (T-P10G).
//
// This is deliberately NOT a fake-deps unit test: the whole point of this
// bug was that GLib.unix_open_pipe()/GLibUnix.open_pipe() are broken when
// called from real GJS/GObject-introspection, in a way no amount of mocking
// GLib would ever catch (a mocked GLib just does whatever the mock author
// assumed). So this test loads the REAL extension/src/core/clipboard.js and
// runs it against the REAL `imports.gi.GLib`/`imports.gi.Gio` — only `Meta`
// (Meta.Selection) is faked, since that genuinely needs a live Mutter
// compositor this test cannot have.
//
// Run under real gjs on Linux (this extension is GNOME-Shell-only; there is
// no macOS gjs). From this directory, with `core/` copied alongside this
// file (mirroring how build.sh lays out a variant):
//   gjs clipboard.readtofd.test.js
// Exits 0 with "ALL PASS" on success, non-zero with "FAILURES: N" otherwise.

imports.searchPath.unshift('.');
const { ClipboardWatcher } = imports.core.clipboard;

const GLib = imports.gi.GLib;
const Gio = imports.gi.Gio;

let passes = 0;
let failures = 0;
function ok(cond, msg) {
  if (cond) { passes++; print(`PASS ${msg}`); }
  else { failures++; print(`FAIL ${msg}`); }
}

const PAYLOAD = 'hello-through-readToFd-real-pipe-substitute-' + 'x'.repeat(200);

// A fake Meta.Selection: transfer_async() writes PAYLOAD into whatever
// Gio.OutputStream readToFd() hands it, exactly like the real
// Meta.Selection would once Meta.SelectionSourceMemory/Meta.Selection are
// actually live -- the part this test cannot exercise without real Mutter.
const fakeSelection = {
  transfer_async(selectionType, mimetype, size, outStream, cancellable, callback) {
    const bytes = [];
    for (let i = 0; i < PAYLOAD.length; i++) bytes.push(PAYLOAD.charCodeAt(i));
    outStream.write_all(bytes, null);
    // Real Meta.Selection completes transfer_finish() asynchronously; an
    // idle callback is enough to prove readToFd()'s callback wiring runs
    // without needing a synchronous fake.
    GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
      callback(this, 'fake-result');
      return GLib.SOURCE_REMOVE;
    });
  },
  transfer_finish(res) {
    return res === 'fake-result';
  },
};

const deps = {
  GLib, Gio, Meta: {},
  global: { display: { get_selection: () => fakeSelection } },
};

const watcher = new ClipboardWatcher(deps, () => {});
const rfd = watcher.readToFd(3 /* arbitrary selection type */, 'text/plain');

ok(typeof rfd === 'number' && rfd >= 0, `readToFd() returned a real fd number: ${rfd}`);
ok(watcher._pendingReadSockets.size === 1, 'the returned fd is held open by _pendingReadSockets');

// Read from the raw fd exactly the way a D-Bus recipient would: no GJS
// wrapper needed at all, just the number readToFd() returned. Using
// Gio.UnixInputStream here is only this TEST's convenience for asserting
// byte content -- the real recipient is a separate OS process.
const loop = GLib.MainLoop.new(null, false);
let readStr = '';
let readOk = false;
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
  try {
    const inStream = new Gio.UnixInputStream({ fd: rfd, close_fd: true });
    const glibBytes = inStream.read_bytes(PAYLOAD.length + 64, null);
    const arr = glibBytes.get_data() || [];
    for (const b of arr) readStr += String.fromCharCode(b);
    readOk = true;
  } catch (e) {
    print('read error: ' + e);
  }
  loop.quit();
  return GLib.SOURCE_REMOVE;
});
loop.run();

ok(readOk, 'reading from the returned fd did not throw');
ok(readStr === PAYLOAD, `bytes written on the write end arrived intact on the read end (${readStr.length}/${PAYLOAD.length} bytes matched: ${readStr === PAYLOAD})`);

// stop() must close any sockets it's still holding, for real -- prove the fd
// actually becomes invalid afterward rather than just checking the Set.
watcher.stop();
ok(watcher._pendingReadSockets.size === 0, 'stop() drains _pendingReadSockets');

print(`\n${passes} passed, ${failures} failed`);
if (failures > 0) {
  print(`FAILURES: ${failures}`);
} else {
  print('ALL PASS');
}
GLib.file_set_contents(
  '/tmp/clipboard_readtofd_test_result.json', JSON.stringify({ passes, failures }));

imports.system.exit(failures > 0 ? 1 : 0);
