// Shell 42-44 entry point: function-based lifecycle, no Extension base class.
const Me = imports.misc.extensionUtils.getCurrentExtension();
const { deps } = Me.imports.imports;
const { ClipboardWatcher } = Me.imports.core.clipboard;
const { InputSynthesizer } = Me.imports.core.input;
const { Placement } = Me.imports.core.placement;
const { Keybindings } = Me.imports.core.keybindings;
const { ShellHelperService } = Me.imports.core.service;
const { IFACE_XML } = Me.imports.core.iface;

let service = null;

function init() { /* nothing: all setup happens in enable() */ }

function enable() {
  const clipboard = new ClipboardWatcher(deps, () => {});
  const input = new InputSynthesizer(deps);
  const placement = new Placement(deps);
  const keybindings = new Keybindings(deps, () => {});
  service = new ShellHelperService(deps, IFACE_XML,
    { clipboard, input, placement, keybindings });
  service.enable();
}

function disable() {
  if (service) { service.disable(); service = null; }
}
