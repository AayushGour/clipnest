import Foundation

/// Outcome of `ModifierReleaseWaiter.waitForRelease()`.
public enum ModifierWaitOutcome: Equatable, Sendable {
  /// All modifiers were observed released within the ceiling.
  case released
  /// The ceiling elapsed while a modifier was still held — the caller must
  /// NOT post the chord (see `ModifierReleaseWaiter`'s doc comment).
  case timedOut
}

/// Waits for the user to physically release every modifier key before a
/// synthesized paste chord is posted — the mandatory mitigation for the
/// D16/D39 bug class on Linux (worse here than macOS: uinput/XTEST-injected
/// events are merged with PHYSICAL key state unconditionally by the
/// kernel, so a hotkey's still-held Ctrl/Super/Shift would ride along into
/// the target app's paste chord).
///
/// Generalizes macOS's fixed-delay `Paster.defaultSynthesisDelay`-adjacent
/// mitigation into an ACTIVELY OBSERVED condition: poll every
/// `pollInterval` (`InputConstants.modifierPollInterval`, ~10ms) for up to
/// `releaseCeiling` (`InputConstants.modifierReleaseCeiling`, 400ms); if a
/// modifier is still asserted once the ceiling passes, give up and report
/// `.timedOut` rather than send a chord with stale modifiers — callers
/// treat `.timedOut` as `PasteError.eventPostFailed`, never send anyway.
///
/// Fully synchronous (blocking) — `EventSynthesizing.synthesizeCommandV`
/// is itself a synchronous, non-`async` protocol requirement (see
/// `ClipnestCore/Paste/EventSynthesizing.swift`), so this cannot suspend;
/// `sleep` defaults to a real blocking implementation
/// (`BlockingSleep.sleep`) and is injected here purely so tests run
/// instantly with no real delay.
public struct ModifierReleaseWaiter: Sendable {
  private let reader: any ModifierMaskReading
  private let pollInterval: Duration
  private let releaseCeiling: Duration
  private let sleep: @Sendable (Duration) -> Void

  public init(
    reader: any ModifierMaskReading,
    pollInterval: Duration = InputConstants.modifierPollInterval,
    releaseCeiling: Duration = InputConstants.modifierReleaseCeiling,
    sleep: @escaping @Sendable (Duration) -> Void = BlockingSleep.sleep
  ) {
    self.reader = reader
    self.pollInterval = pollInterval
    self.releaseCeiling = releaseCeiling
    self.sleep = sleep
  }

  /// Checks `reader` immediately (an already-released hotkey costs
  /// nothing), then every `pollInterval` until either the mask reads empty
  /// (`.released`) or `releaseCeiling` total elapsed time is exceeded
  /// (`.timedOut`).
  public func waitForRelease() -> ModifierWaitOutcome {
    var elapsed = Duration.zero
    while true {
      if reader.currentModifierMask().isEmpty { return .released }
      if elapsed >= releaseCeiling { return .timedOut }
      sleep(pollInterval)
      elapsed += pollInterval
    }
  }
}
