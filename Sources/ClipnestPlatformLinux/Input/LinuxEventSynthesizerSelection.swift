import Foundation

/// Which backend `LinuxEventSynthesizerFactory` picked, and why — surfaced
/// so the composition root can log (metadata only) which paste path is
/// active for support/diagnostics.
public enum SelectedEventSynthesizerKind: Sendable, Equatable {
  case uinput
  case xtest
  case clipboardOnly
}

/// Pure priority decision — uinput first (works on X11 AND Wayland), then
/// XTEST (X11 sessions only — see `XTestEventSynthesizer`'s doc comment on
/// why it must never even be attempted on Wayland), then the
/// clipboard-only fallback.
///
/// Extracted from the actual probing (opening `/dev/uinput`, opening a
/// display — both real, unverifiable-in-CI I/O) so the DECISION LOGIC
/// itself is unit-testable independent of real device/display
/// availability.
public enum LinuxEventSynthesizerSelection {
  public static func choose(
    uinputAvailable: Bool, sessionType: SessionType, xtestAvailable: Bool
  ) -> SelectedEventSynthesizerKind {
    if uinputAvailable { return .uinput }
    if sessionType == .x11, xtestAvailable { return .xtest }
    return .clipboardOnly
  }
}
