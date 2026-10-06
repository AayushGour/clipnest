import Foundation

/// Synthesizes a ⌘V keystroke targeting a specific app.
///
/// Injected into `Paster` (plan task T15) so tests exercise the paste flow
/// with a mock instead of ever posting a real key event — see
/// `.claude/coding-standards.md`'s testing rules ("never synthesize real key
/// events... from a test") and the spec's explicit CI-safety requirement.
///
/// The real, `CGEvent`-based implementation is `CGEventSynthesizer`
/// (`Platform/macOS/CGEventSynthesizer.swift`).
public protocol EventSynthesizing: Sendable {
  /// Synthesizes and posts a ⌘V key-down/key-up pair.
  ///
  /// `app` is `nil` only when `Paster.synthesizesWithoutVerifiedTarget` is
  /// `true` AND `Paster.paste` had no verified target to give it (see that
  /// property's doc comment — T-WLPASTE-NIL1) — meaning "post globally,
  /// there is no specific process to target," not "target unknown, guess."
  /// Every macOS call site always passes a non-`nil` target: `Paster`
  /// defaults `synthesizesWithoutVerifiedTarget` to `false` on every
  /// platform, and macOS never overrides it. A conforming type that only
  /// ever runs on macOS (`CGEventSynthesizer`) can therefore keep ignoring
  /// `app` exactly as it always has; a Linux backend (`UInputEventSynthesizer`/
  /// `XTestEventSynthesizer`) must handle `nil` sensibly (posting globally,
  /// with no terminal-app-specific modifier guess — see those types' own
  /// doc comments).
  /// - Throws: `PasteError.eventPostFailed` if the underlying event(s)
  ///   could not be created or posted.
  func synthesizeCommandV(targeting app: FrontmostAppRef?) throws
}

#if !os(macOS)
  extension PlatformDefaults {
    /// No real key-event backend exists yet outside macOS. `Paster` never
    /// reaches this by default anyway — `PlatformDefaults.isAccessibilityGranted`
    /// (`Paster.swift`) defaults to `false` off Apple platforms, so
    /// `paste(_:targetingFrontmostApp:)` always takes its documented
    /// "no Accessibility → clipboard-only" fallback before this would ever be
    /// invoked. Never used in production; the Linux composition root always
    /// injects a real backend (uinput/XTEST/extension — see
    /// `PlatformDefaults.swift`'s doc comment).
    public static var eventSynthesizer: any EventSynthesizing { NoOpEventSynthesizing() }
  }

  /// Portable no-op `EventSynthesizing` — see the `#if !os(macOS)`
  /// `PlatformDefaults.eventSynthesizer` doc comment above.
  private struct NoOpEventSynthesizing: EventSynthesizing {
    func synthesizeCommandV(targeting app: FrontmostAppRef?) throws {}
  }
#endif
