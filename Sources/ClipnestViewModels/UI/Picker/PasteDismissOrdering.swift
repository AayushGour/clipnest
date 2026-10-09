import Foundation

/// When the picker hides relative to the pasteboard write on a paste.
///
/// A required `PickerViewModel` initializer parameter, deliberately without a
/// default: the two platforms need OPPOSITE orders, and a silent default would
/// let one of them quietly get the other's (coding-standards.md, "A
/// cross-platform seam MUST NOT have a silent default").
public enum PasteDismissOrdering: Equatable, Sendable {
  /// Hide the picker, then write the pasteboard, then (after
  /// `Paster.synthesisDelay`) synthesize the paste. macOS: the global HID
  /// event tap would otherwise risk delivering the synthetic Cmd+V to the
  /// picker's own search field, and `NSPasteboard` writes need no focus.
  case dismissBeforeWrite

  /// Write the pasteboard while the picker still has keyboard focus, wait up
  /// to `confirmationTimeout` for the write to become visible, THEN hide, then
  /// synthesize the paste. Linux/Wayland: mutter ignores
  /// `wl_data_device.set_selection` from a client that has lost keyboard focus,
  /// so a write issued after the hide is silently dropped and the synthesized
  /// Ctrl+V pastes the PREVIOUS clipboard content.
  case writeBeforeDismiss(confirmationTimeout: Duration)

  /// How long Linux waits for its own write to show up (as a pasteboard change
  /// count bump) before hiding anyway. Bounded so a compositor/bridge that
  /// never reports the change cannot keep the picker on screen.
  public static let defaultConfirmationTimeout: Duration = .milliseconds(250)

  /// How often the confirmation wait re-reads the pasteboard change count.
  static let confirmationPollInterval: Duration = .milliseconds(10)
}
