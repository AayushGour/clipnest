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
    const clipboard = new ClipboardWatcher(deps, (...a) => this._onClipboard(...a));
    const input = new InputSynthesizer(deps);
    const placement = new Placement(deps);
    const keybindings = new Keybindings(deps, (a) => this._onShortcut(a));
    this._service = new ShellHelperService(deps, IFACE_XML,
      { clipboard, input, placement, keybindings });
    this._service.enable();
  }
  disable() { this._service?.disable(); this._service = null; }
  _onClipboard() { /* forwarded by the service */ }
  _onShortcut() { /* forwarded by the service */ }
}
