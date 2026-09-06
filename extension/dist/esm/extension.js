import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import { deps } from './imports.js';
import { ClipboardWatcher } from './core/clipboard.js';
import { InputSynthesizer } from './core/input.js';
import { Placement } from './core/placement.js';
import { Keybindings } from './core/keybindings.js';
import { ShellHelperService } from './core/service.js';
import { IFACE_XML } from './core/iface.js';

export default class ClipnestExtension extends Extension {
  enable() {
    // `service` is assigned below, before `service.enable()` runs — by the
    // time mutter can actually FIRE either callback (a real clipboard
    // change, a real shortcut activation), `service` is always set. This is
    // what lets `ClipboardWatcher`/`Keybindings` be constructed before the
    // service that owns emitting their D-Bus signals exists yet.
    let service;
    const clipboard = new ClipboardWatcher(
      deps, (...a) => service.notifyClipboardChanged(...a));
    const input = new InputSynthesizer(deps);
    const placement = new Placement(deps);
    const keybindings = new Keybindings(deps, (a) => service.notifyShortcutActivated(a));
    service = new ShellHelperService(deps, IFACE_XML,
      { clipboard, input, placement, keybindings });
    this._service = service;
    service.enable();
  }
  disable() { this._service?.disable(); this._service = null; }
}
