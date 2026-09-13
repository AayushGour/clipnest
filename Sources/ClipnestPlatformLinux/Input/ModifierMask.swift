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
/// supplying the mask over its own IPC channel (a separate, not-yet-built
/// task); until that lands, `NullModifierMaskReader` (always reports
/// "nothing held") is the documented fallback used whenever no X11 display
/// is reachable — see `LinuxEventSynthesizerFactory`.
///
/// **The gap is WIDER than the paragraph above says, and this was measured
/// (T-COPYFLAKE1, 2026-09-13), not reasoned about.** On a GNOME Wayland
/// session XWayland IS reachable, so the factory picks
/// `X11ModifierMaskReader`, not `NullModifierMaskReader` — and that reader
/// is blind in exactly the same way while REPORTING SUCCESS: with a
/// native-Wayland window focused, `XQueryPointer` returns success with an
/// empty state mask even while Shift/Super are physically held (8/8 probe
/// samples). So on the single most common Linux desktop configuration this
/// protocol's production conformance silently answers "nothing held",
/// always, and `ModifierReleaseWaiter` is inert rather than absent.
///
/// Both conformances therefore share one defect this protocol's SHAPE
/// permits: `currentModifierMask()` has no way to say "I cannot tell".
/// Whatever supplies the real Wayland reading should arrive together with
/// a third state, or every future backend will be free to make the same
/// mistake silently.
public protocol ModifierMaskReading: Sendable {
  func currentModifierMask() -> ModifierMask
}
