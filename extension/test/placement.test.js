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

// `frame` defaults to the real picker's default size
// (`PickerWindow.defaultWidth`/`Height`, `Sources/ClipnestGTK/Window/
// PickerWindow.swift`) — overridable per test for the clamp cases below,
// which need to prove the clamp uses the window's REAL frame size
// (`get_frame_rect()`), not a hardcoded constant.
function makeWindow({ wmClass, title, frame }) {
  const actor = new FakeEmitter();
  const win = {
    get_wm_class: () => wmClass,
    get_title: () => title,
    _actor: actor,
    get_compositor_private: () => actor,
    get_frame_rect: () => frame || { width: 560, height: 420 },
    move_frame(userOp, x, y) { this._movedTo = [x, y]; },
    make_above() { this._above = true; },
    stick() { this._sticky = true; },
  };
  return win;
}

// `workAreaByMonitor` (default: a single monitor 0, matching the real
// `GetMonitorWorkArea` reading confirmed live against a 1440x900 screen in
// `packaging/linux/gnome-shell-test/README.md`'s Findings: `(0, 32, 1440,
// 868)`) lets the clamp tests below pick which monitor's work area a given
// target point resolves to, and `monitorForPoint` (default: always 0)
// stands in for `global.display.get_monitor_index_for_rect` — a real
// `Meta.Rectangle`-taking Mutter API this module already calls the same
// way in `getPointer()`, faked here as an injectable function so a test
// can prove `_place()` picks the monitor the TARGET point falls in.
function makeDisplay(windowActors, { workAreaByMonitor, monitorForPoint } = {}) {
  const areas = workAreaByMonitor || { 0: { x: 0, y: 32, width: 1440, height: 868 } };
  const display = new FakeEmitter();
  display.get_monitor_index_for_rect = monitorForPoint || (() => 0);
  const workspace = { get_work_area_for_monitor: monitor => areas[monitor] };
  const global = {
    display,
    get_window_actors: () => windowActors.map(w => ({ meta_window: w })),
    workspace_manager: { get_active_workspace: () => workspace },
  };
  // A real `Meta.Rectangle` is a GObject-boxed type constructed from a
  // plain `{x, y, width, height}` — `_place()`/`getPointer()` only ever
  // read it back as such (never any other `Meta.Rectangle` method), so a
  // plain pass-through fake is a faithful stand-in for this module's own
  // pure-JS unit tests (matching this file's own "unit-testable under a
  // bare gjs" design, see the header comment).
  const Meta = { Rectangle: function (fields) { return fields; } };
  return { global, display, Meta };
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
  const { global, Meta } = makeDisplay([picker]);
  const p = new Placement({ global, Meta });

  const placed = p.placeWindow('picker', 100, 200, 0);
  ok(placed === true, 'placeWindow() returns true when the target window already exists');
  ok(picker._movedTo[0] === 100 && picker._movedTo[1] === 200,
    'placeWindow() moved the real window to (100,200) unchanged -- well within the work area, nothing to clamp');
}

// --- 3: placeWindow() queues by ROLE (not title) when the window is not yet
//        mapped, and applies it on first-frame, matched via reverse role
//        lookup from the window's (fixed) title ---
{
  const { global, display, Meta } = makeDisplay([]);
  const p = new Placement({ global, Meta });
  p.start();

  const queued = p.placeWindow('picker', 10, 20, 3 /* above + sticky */);
  ok(queued === false, 'placeWindow() returns false (queued) when no matching window exists yet');

  // Simulate the picker window actually getting created + mapped.
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest' });
  display.emit('window-created', picker);
  picker._actor.emit('first-frame');

  // y=20 is clamped up to the default work area's own top edge (y=32,
  // mirroring the real 32px GNOME panel struct off this file's default
  // fixture) -- x=10 is untouched since it already fits; see block 6-10
  // below for the clamp formula's own dedicated coverage.
  ok(picker._movedTo && picker._movedTo[0] === 10 && picker._movedTo[1] === 32,
    'queued placement is applied on first-frame (clamped up to the work area top), matched by wm_class + role reverse-lookup');
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

// --- 6: _clampOrigin() -- the pure formula, hand-computed cases mirroring
//        WindowPlacementTests.swift's own coverage of the Swift original
//        (Tests/ClipnestViewModelsTests/WindowPlacementTests.swift) this
//        is a deliberate port of. No fakes needed: `_clampOrigin` touches
//        no `this._d`/Meta/global, only its plain-value arguments.
{
  const p = new Placement({});
  const workArea = { x: 0, y: 32, width: 1440, height: 868 };

  ok(
    JSON.stringify(p._clampOrigin(300, 200, 560, 420, workArea)) === JSON.stringify([300, 200]),
    '_clampOrigin() leaves an origin already fully inside the work area unchanged');

  ok(
    JSON.stringify(p._clampOrigin(-50, -10, 560, 420, workArea)) === JSON.stringify([0, 32]),
    '_clampOrigin() clamps an origin below/left of the work area up to its min edge');

  ok(
    JSON.stringify(p._clampOrigin(1430, 600, 560, 420, workArea))
      === JSON.stringify([1440 - 560, 32 + 868 - 420]),
    '_clampOrigin() clamps an origin whose window would overflow the right/bottom edge back onto screen');

  ok(
    JSON.stringify(p._clampOrigin(700, 700, 2000, 2000, workArea)) === JSON.stringify([0, 32]),
    '_clampOrigin() clamps to the work area\'s min edge when the window is larger than the work area itself');
}

// --- 7: placeWindow() clamps the real, reported bug -- picker placed at
//        the cursor (300, 600) on a 900px-tall screen (868px-tall work
//        area under a 32px panel) with a 420px-tall frame used to run
//        17px+3px past the bottom edge; also proves the X axis is left
//        alone here since 300 already fits (only Y needed clamping) ---
{
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest', frame: { width: 560, height: 420 } });
  const { global, Meta } = makeDisplay([picker]);
  const p = new Placement({ global, Meta });

  p.placeWindow('picker', 300, 600, 0);
  ok(JSON.stringify(picker._movedTo) === JSON.stringify([300, 32 + 868 - 420]),
    'placeWindow() clamps the exact devops-reported repro (300,600 on a 900px screen) fully onto the work area');
}

// --- 8: placeWindow() clamps a right-edge overflow (cursor near the
//        screen's right edge, window wider than the remaining room) ---
{
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest', frame: { width: 560, height: 420 } });
  const { global, Meta } = makeDisplay([picker]);
  const p = new Placement({ global, Meta });

  p.placeWindow('picker', 1430, 400, 0);
  ok(JSON.stringify(picker._movedTo) === JSON.stringify([1440 - 560, 400]),
    'placeWindow() clamps a right-edge overflow back onto the work area, leaving Y alone');
}

// --- 9: placeWindow() clamps a genuinely negative target (e.g. a
//        multi-monitor negative-coordinate layout) up to the work area's
//        own left edge, not just a small positive one ---
{
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest', frame: { width: 560, height: 420 } });
  const { global, Meta } = makeDisplay([picker]);
  const p = new Placement({ global, Meta });

  p.placeWindow('picker', -80, 400, 0);
  ok(JSON.stringify(picker._movedTo) === JSON.stringify([0, 400]),
    'placeWindow() clamps a negative X up to the work area\'s left edge');
}

// --- 10: the clamp resolves the work area for the MONITOR THE TARGET
//         POINT falls in, not always monitor 0 -- and flags (above/stick)
//         still apply alongside a clamped position ---
{
  const picker = makeWindow({ wmClass: 'clipnest', title: 'Clipnest', frame: { width: 560, height: 420 } });
  const { global, Meta } = makeDisplay([picker], {
    workAreaByMonitor: {
      0: { x: 0, y: 32, width: 1440, height: 868 },
      1: { x: 1440, y: 0, width: 1920, height: 1080 },
    },
    monitorForPoint: () => 1,
  });
  const p = new Placement({ global, Meta });

  p.placeWindow('picker', 3300, 1000, 3 /* above + sticky */);
  ok(JSON.stringify(picker._movedTo) === JSON.stringify([1440 + 1920 - 560, 1080 - 420]),
    'placeWindow() clamps against the TARGET point\'s own monitor work area (monitor 1), not monitor 0\'s');
  ok(picker._above === true && picker._sticky === true,
    'flags (above + sticky) still apply alongside a clamped position');
}

print(`\n${passes} passed, ${failures} failed`);
if (failures > 0) {
  print(`FAILURES: ${failures}`);
} else {
  print('ALL PASS');
}
imports.system.exit(failures > 0 ? 1 : 0);
