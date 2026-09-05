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
  /// Synthesizes and posts a ⌘V key-down/key-up pair targeting `app`.
  /// - Throws: `PasteError.eventPostFailed` if the underlying event(s)
  ///   could not be created or posted.
  func synthesizeCommandV(targeting app: FrontmostAppRef) throws
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
    func synthesizeCommandV(targeting app: FrontmostAppRef) throws {}
  }
#endif
