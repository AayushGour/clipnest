'use strict';
// Unit test for Placement's window-identity logic (T-RT3): wm_class + role
// matching instead of a UUID window title. Pure logic over injected deps —
// no real Meta/Mutter needed, matching this module's own "unit-testable
// under a bare gjs" design (see placement.js's header comment).
//
// Run: gjs placement.test.js
// Exits 0 with "ALL PASS" on success, non-zero with "FAILURES: N" otherwise.

imports.searchPath.unshift('.');
const { Placement } = imports.core.placement;

let passes = 0;
let failures = 0;
function ok(cond, msg) {
  if (cond) { passes++; print(`PASS ${msg}`); }
  else { failures++; print(`FAIL ${msg}`); }
}

// --- a minimal fake signal emitter, enough for start()/_applyPending() ---
class FakeEmitter {
  constructor() { this._handlers = new Map(); this._nextId = 1; }
  connect(signal, cb) {
    const id = this._nextId++;
    this._handlers.set(id, { signal, cb });
    return id;
  }
  disconnect(id) { this._handlers.delete(id); }
  emit(signal, ...args) {
    for (const { signal: s, cb } of this._handlers.values()) {
      if (s === signal) cb(this, ...args);
    }
  }
}

function makeWindow({ wmClass, title }) {
  const actor = new FakeEmitter();
  const win = {
    get_wm_class: () => wmClass,
    get_title: () => title,
    _actor: actor,
    get_compositor_private: () => actor,
    move_frame(userOp, x, y) { this._movedTo = [x, y]; },
    make_above() { this._above = true; },
    stick() { this._sticky = true; },
  };
  return win;
}

function makeDisplay(windowActors) {
  const display = new FakeEmitter();
  const global = {
    display,
    get_window_actors: () => windowActors.map(w => ({ meta_window: w })),
  };
  return { global, display };
}

// --- 1: _ourWindows / _findByToken filter by wm_class, not title alone ---
{
  const ourPicker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest' });
  const impostor = makeWindow({ wmClass: 'evil-app', title: 'Clipnest' }); // same title, foreign app
  const ourSomethingElse = makeWindow({ wmClass: 'clipnest', title: 'Clipnest Settings' });
  const { global } = makeDisplay([ourPicker, impostor, ourSomethingElse]);
  const p = new Placement({ global });

  const found = p._findByToken('picker');
  ok(found === ourPicker, '_findByToken("picker") finds the real picker (matches wm_class + title)');
  ok(found !== impostor, '_findByToken("picker") ignores a same-titled window from a different wm_class');
  ok(p._findByToken('not-a-real-role') === null, '_findByToken() with an unknown role returns null');
  ok(p._ourWindows().length === 2, '_ourWindows() only counts wm_class === "clipnest" windows (2 of 3)');
}

// --- 2: placeWindow() applies immediately when the window already exists ---
{
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest' });
  const { global } = makeDisplay([picker]);
  const p = new Placement({ global });

  const placed = p.placeWindow('picker', 100, 200, 0);
  ok(placed === true, 'placeWindow() returns true when the target window already exists');
  ok(picker._movedTo[0] === 100 && picker._movedTo[1] === 200, 'placeWindow() moved the real window to (100,200)');
}

// --- 3: placeWindow() queues by ROLE (not title) when the window is not yet
//        mapped, and applies it on first-frame, matched via reverse role
//        lookup from the window's (fixed) title ---
{
  const { global, display } = makeDisplay([]);
  const p = new Placement({ global });
  p.start();

  const queued = p.placeWindow('picker', 10, 20, 3 /* above + sticky */);
  ok(queued === false, 'placeWindow() returns false (queued) when no matching window exists yet');

  // Simulate the picker window actually getting created + mapped.
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest' });
  display.emit('window-created', picker);
  picker._actor.emit('first-frame');

  ok(picker._movedTo && picker._movedTo[0] === 10 && picker._movedTo[1] === 20,
    'queued placement is applied on first-frame, matched by wm_class + role reverse-lookup');
  ok(picker._above === true && picker._sticky === true, 'flags (above + sticky) applied along with position');
}

// --- 4: a same-titled window from a DIFFERENT app must not consume the
//        queued placement meant for our own picker ---
{
  const { global, display } = makeDisplay([]);
  const p = new Placement({ global });
  p.start();
  p.placeWindow('picker', 5, 6, 0);

  const impostor = makeWindow({ wmClass: 'not-clipnest', title: 'Clipnest' });
  display.emit('window-created', impostor);
  impostor._actor.emit('first-frame');

  ok(impostor._movedTo === undefined, 'a foreign window with the same title never gets placed');
  ok(p._pending.has('picker'), 'the queued request for "picker" is still pending after the impostor is ignored');
}

// --- 5: unplaceWindow() cancels a queued request ---
{
  const { global, display } = makeDisplay([]);
  const p = new Placement({ global });
  p.start();
  p.placeWindow('picker', 1, 2, 0);
  p.unplaceWindow('picker');

  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest' });
  display.emit('window-created', picker);
  picker._actor.emit('first-frame');

  ok(picker._movedTo === undefined, 'unplaceWindow() cancels the queued request before the window ever maps');
}

print(`\n${passes} passed, ${failures} failed`);
if (failures > 0) {
  print(`FAILURES: ${failures}`);
} else {
  print('ALL PASS');
}
imports.system.exit(failures > 0 ? 1 : 0);
