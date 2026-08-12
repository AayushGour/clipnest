import Foundation

/// Synthesizes a ⌘V keystroke targeting a specific app.
///
/// Injected into `Paster` (plan task T15) so tests exercise the paste flow
/// with a mock instead of ever posting a real key event — see
/// `.claude/coding-standards.md`'s testing rules ("never synthesize real key
/// events... from a test") and the spec's explicit CI-safety requirement.
///
/// The real, `CGEvent`-based implementation is `CGEventSynthesizer`
/// (`Paster.swift`).
public protocol EventSynthesizing: Sendable {
  /// Synthesizes and posts a ⌘V key-down/key-up pair targeting `app`.
  /// - Throws: `PasteError.eventPostFailed` if the underlying event(s)
  ///   could not be created or posted.
  func synthesizeCommandV(targeting app: FrontmostAppRef) throws
}
