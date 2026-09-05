import Foundation

/// The physical modifier keys `ModifierReleaseWaiter` cares about.
public struct ModifierMask: OptionSet, Sendable, Equatable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let control = ModifierMask(rawValue: 1 << 0)
  public static let shift = ModifierMask(rawValue: 1 << 1)
  public static let alt = ModifierMask(rawValue: 1 << 2)
  public static let superKey = ModifierMask(rawValue: 1 << 3)
}

/// Reads the CURRENT physical modifier-key state, injected so
/// `ModifierReleaseWaiter`'s poll loop is testable without a real X
/// display. On X11 the production implementation
/// (`X11ModifierMaskReader`) uses `XQueryPointer`.
///
/// **The Wayland gap:** there is no client-side API at all for reading
/// physical modifier state on native Wayland — only the compositor knows
/// it. The eventual Wayland reader is a GNOME Shell extension companion
/// process supplying the mask over its own IPC channel (a separate,
/// not-yet-built task); until that lands, `NullModifierMaskReader` (always
/// reports "nothing held") is the documented fallback used whenever no X11
/// display is reachable — see `LinuxEventSynthesizerFactory`.
public protocol ModifierMaskReading: Sendable {
  func currentModifierMask() -> ModifierMask
}
