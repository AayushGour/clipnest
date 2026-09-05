import Foundation

/// The negotiated state of the optional GNOME Shell extension: whether it's
/// present at all, and which features it currently advertises. Recomputed
/// on every `NameOwnerChanged`/`CapabilitiesChanged` observation so
/// enabling or disabling the extension takes effect live, with no restart
/// — see `ShellHelperClient`'s doc comment.
///
/// Pure and I/O-free: everything here is a function of already-decoded
/// strings, never a live D-Bus call, so the negotiation logic itself
/// (which capability strings this app recognizes, what "the extension is
/// unusable" means even though its bus name is owned) is directly
/// unit-testable.
public struct ShellHelperCapabilities: Equatable, Sendable {
  public let isPresent: Bool
  public let capabilities: Set<ShellHelperCapability>

  public static let unavailable = ShellHelperCapabilities(isPresent: false, capabilities: [])

  public init(isPresent: Bool, capabilities: Set<ShellHelperCapability>) {
    self.isPresent = isPresent
    self.capabilities = capabilities
  }

  /// Builds the negotiated state from `NameHasOwner`'s boolean answer and
  /// the raw `Capabilities` property's `as` (array-of-string) value.
  /// Unrecognized capability strings (a future extension version
  /// advertising something this app's build predates) are silently
  /// dropped rather than treated as a parse failure — the whole point of
  /// a capability LIST, per the contract XML's own framing, is that a
  /// caller degrades per-feature instead of all-or-nothing.
  public static func negotiate(nameHasOwner: Bool, rawCapabilities: [String])
    -> ShellHelperCapabilities
  {
    guard nameHasOwner else { return .unavailable }
    let recognized = Set(rawCapabilities.compactMap(ShellHelperCapability.init(rawValue:)))
    return ShellHelperCapabilities(isPresent: true, capabilities: recognized)
  }

  public func supports(_ capability: ShellHelperCapability) -> Bool {
    isPresent && capabilities.contains(capability)
  }

  /// Whether the extension can be used as the input-synthesis backend
  /// (`SendKeyChord`/`FocusAndSendKeyChord`) in place of uinput/XTEST.
  public var canSynthesizeKeystrokes: Bool { supports(.paste) }

  /// Whether the extension's mutter-level keybinding tier
  /// (`app.clipnest.Clipnest.Keybindings` + its `ShortcutActivated`
  /// signal) is live — see `HotkeyBackend`'s priority chain.
  public var canDeliverShortcuts: Bool { supports(.hotkeys) }

  /// Whether `GetPointer`/`GetFocusedApp` can supply `ShowPicker`'s
  /// pointer/focus options without this app needing its own X11-only
  /// fallback for them.
  public var canResolvePointerAndFocus: Bool { supports(.pointer) && supports(.focus) }

  public var canPlaceWindows: Bool { supports(.placement) }
}
