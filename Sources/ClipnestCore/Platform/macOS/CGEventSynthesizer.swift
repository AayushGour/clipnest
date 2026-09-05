#if os(macOS)
  import CoreGraphics
  import Foundation

  /// Real, `CGEvent`-based `EventSynthesizing` implementation: synthesizes a ⌘V
  /// key-down/key-up pair and posts it through the global HID event tap.
  ///
  /// Never exercised by `ClipnestCoreTests` — `PasterTests` uses a mock
  /// `EventSynthesizing` instead, per the spec's explicit "no real key events
  /// synthesized in CI" requirement.
  public struct CGEventSynthesizer: EventSynthesizing {
    /// Virtual keycode for "V" (`kVK_ANSI_V`), from Carbon's `HIToolbox` keycode table.
    private static let vKeyCode: CGKeyCode = 0x09

    public init() {}

    /// Posts a synthetic ⌘V through the global HID event tap
    /// (`CGEvent.post(tap: .cghidEventTap)`) rather than targeting `app`'s pid
    /// directly (`CGEvent.postToPid(_:)`, this type's original implementation) —
    /// pid-targeted posting proved unreliable in practice for delivering a
    /// synthetic keystroke to a previously-frontmost app (macOS's
    /// window-server-level event routing doesn't always honor it the way a
    /// real keystroke injected through the global HID tap is honored).
    /// `app` is accepted for `EventSynthesizing`'s protocol contract (and
    /// still meaningfully asserted on by `PasterTests`' mock, which verifies
    /// `Paster` computes and passes the right target) but is otherwise unused
    /// by this global-post implementation — correctness now depends on the
    /// target app actually holding key focus by the time this posts. `Paster.paste`
    /// is responsible for both waiting `synthesisDelay` beforehand and
    /// re-verifying `app` is still frontmost immediately before calling this
    /// (see `PasteError.targetNoLongerFrontmost`) — this type only builds and
    /// posts the chord, via the shared `SyntheticKeystroke` (see M-1: the same
    /// helper `ClipboardSelectionReplacer` uses for its ⌘C/⌘V, so there is one
    /// place that builds and posts synthetic modified keystrokes).
    public func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
      guard SyntheticKeystroke.postCommandModified(Self.vKeyCode) else {
        throw PasteError.eventPostFailed
      }
    }
  }

  extension PlatformDefaults {
    /// The production `EventSynthesizing` on macOS. See `PlatformDefaults`'s
    /// own doc comment for why this is a static member here rather than a
    /// literal default-argument value in `Paster.swift`.
    public static var eventSynthesizer: any EventSynthesizing { CGEventSynthesizer() }
  }

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
  /// `CGEventSynthesizer.synthesizeCommandV` (picker paste, ⌘V — this file)
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
#endif
