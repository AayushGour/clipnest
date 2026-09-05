import Foundation

/// A keycode plus the shift state required to produce a given character
/// under the CURRENTLY ACTIVE keyboard layout.
public struct ResolvedKey: Sendable, Equatable {
  /// X11 keycode (kernel/evdev keycode + `InputConstants.x11KernelKeycodeOffset`).
  /// `XTestEventSynthesizer` uses this directly; `UInputEventSynthesizer`
  /// subtracts the offset to get the kernel keycode `/dev/uinput` expects.
  public var x11Keycode: Int32
  /// Whether Shift must be held (in addition to whatever chord modifiers
  /// the caller already wants, e.g. Ctrl) to produce `character` at this
  /// keycode.
  public var requiresShift: Bool

  public init(x11Keycode: Int32, requiresShift: Bool) {
    self.x11Keycode = x11Keycode
    self.requiresShift = requiresShift
  }
}

/// Resolves a character to a physical key, honoring the ACTIVE keyboard
/// layout — NEVER guesses. uinput and XTEST both speak keycodes, not
/// characters: on Dvorak/AZERTY/Colemak the physical key at the kernel's
/// fixed `KEY_V` position does not produce `v`.
///
/// Implementations must return `nil` (never a best-effort/likely-wrong
/// keycode) when the layout cannot produce `character` at shift level 0 or
/// 1 of its primary group — callers then fall back to clipboard-only
/// rather than risk typing the wrong character (or, worse, a keystroke
/// that means something else entirely in the target app).
public protocol KeyboardLayoutResolving: Sendable {
  func resolve(character: Character) -> ResolvedKey?
}
