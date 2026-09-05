'use strict';
// Synthetic input via Clutter's virtual device.
//
// notify_keyval takes a KEYVAL, not a keycode — the compositor maps it through
// the current XKB layout itself. That eliminates the entire keyboard-layout
// problem the uinput and XTEST backends have to solve by hand.
var InputSynthesizer = class InputSynthesizer {
  constructor(deps) {
    this._d = deps;
    this._device = null;
  }

  _ensureDevice() {
    if (this._device) return this._device;
    const { Clutter } = this._d;
    const seat = Clutter.get_default_backend().get_default_seat();
    this._device = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    return this._device;
  }

  destroy() { this._device = null; }

  sendChord(keyval, modifierKeyvals) {
    const { Clutter } = this._d;
    const dev = this._ensureDevice();
    const t = Clutter.get_current_event_time() * 1000;
    let i = 0;
    for (const m of modifierKeyvals)
      dev.notify_keyval(t + i++, m, Clutter.KeyState.PRESSED);
    dev.notify_keyval(t + i++, keyval, Clutter.KeyState.PRESSED);
    dev.notify_keyval(t + i++, keyval, Clutter.KeyState.RELEASED);
    for (const m of [...modifierKeyvals].reverse())
      dev.notify_keyval(t + i++, m, Clutter.KeyState.RELEASED);
    return true;
  }

  /// Focus the target and send the chord in ONE compositor main-loop turn.
  ///
  /// This is strictly safer than the macOS equivalent, which writes the
  /// pasteboard, waits a fixed delay, re-checks the frontmost app, then posts.
  /// Here there is no delay and no window in which focus can move, so the
  /// `targetNoLongerFrontmost` race cannot occur — it becomes a clean
  /// 'target-lost' return instead.
  focusAndSendChord(window, keyval, modifierKeyvals) {
    if (!window || window.get_compositor_private() === null) return 'target-lost';
    const now = this._d.global.get_current_time();
    window.focus(now);
    window.activate(now);
    return this.sendChord(keyval, modifierKeyvals) ? 'ok' : 'unsupported';
  }
};
