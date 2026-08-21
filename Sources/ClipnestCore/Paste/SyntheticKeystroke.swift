import CoreGraphics
import Foundation

/// Posts a synthetic Command-modified key chord (⌘+`key`) through the global
/// HID event tap, from an event source that neither inherits the user's
/// currently-held physical modifiers nor leaks its own synthetic state into
/// the shared session state.
///
/// Never exercised by `ClipnestCoreTests` — this posts a real `CGEvent`, and
/// `Paster`'s caller-facing surface sits behind the mockable
/// `EventSynthesizing` seam (`CGEventSynthesizer` is the real implementation
/// that calls this; `PasterTests` uses a mock `EventSynthesizing` instead),
/// so tests never have to invoke this directly, per coding-standards.md's
/// "never synthesize real key events... from a test." `ClipboardSelectionReplacer`
/// (`ClipnestApp`, untested today — see that file's header comment) also
/// calls this directly for its ⌘C/⌘V.
///
/// Extracted as the ONE place that builds and posts these events — both
/// `CGEventSynthesizer.synthesizeCommandV` (picker paste, ⌘V — `Paster.swift`)
/// and `ClipboardSelectionReplacer.postCommandKey` (⌥⌘E snippet expansion,
/// ⌘C then ⌘V — `ClipnestApp/Sources/System/ClipboardSelectionReplacer.swift`)
/// route through this instead of each hand-rolling its own
/// `CGEventSource`/`CGEvent` pair. Before this existed, a fix applied to only
/// one of those two call sites would have left the other silently broken.
///
/// Fixes two defects present in the naive "keyDown/keyUp with
/// `.flags = .maskCommand`" approach both call sites used previously:
/// 1. `CGEventSource(stateID: .combinedSessionState)` MERGES the user's
///    physically-held modifiers into the synthetic event's state. Since the
///    picker opens on ⌥⌘V and snippet expansion on ⌥⌘E, the user is very
///    likely still physically holding Option/Command at the moment this
///    fires — so the target app could receive ⌥⌘V instead of a clean ⌘V.
///    `.privateState` does not merge physical modifier state, and doesn't
///    contribute its own synthetic state back to the session either.
/// 2. Command was asserted purely via `.flags` on the letter-key events,
///    with no bracketing modifier transition and nothing that explicitly
///    returned the modifier state to released. This brackets the letter key
///    with an actual Command key-down before it and a Command key-up after
///    it (mirroring how a real Command press arrives at the HID level), so
///    no modifier is left asserted once this returns.
public enum SyntheticKeystroke {
  /// Virtual keycode for the physical Command key (`kVK_Command`), from
  /// Carbon's `HIToolbox` keycode table.
  private static let commandKeyCode: CGKeyCode = 0x37

  /// Posts, in order: Command key-down, `key` key-down, `key` key-up,
  /// Command key-up — all four events built from one `.privateState`
  /// `CGEventSource` and posted through `.cghidEventTap`.
  ///
  /// - Returns: `false` if any of the four events couldn't be created
  ///   (source exhaustion or an invalid keycode) — nothing is posted in that
  ///   case. `true` once all four have been posted.
  public static func postCommandModified(_ key: CGKeyCode) -> Bool {
    let source = CGEventSource(stateID: .privateState)

    guard
      let commandDown = CGEvent(
        keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
      let commandUp = CGEvent(
        keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
    else {
      return false
    }

    commandDown.flags = .maskCommand
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    commandUp.flags = []

    commandDown.post(tap: .cghidEventTap)
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    commandUp.post(tap: .cghidEventTap)

    return true
  }
}
