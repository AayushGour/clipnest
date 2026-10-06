import Foundation

/// A reference to a specific running app, captured at a point in time, that
/// `EventSynthesizing`/`Paster` (plan task T15) can target for a synthesized
/// ⌘V paste.
///
/// Carries a process identifier (not just a bundle ID) because `CGEvent`
/// posting needs a concrete process to target via `postToPid` — a bundle ID
/// alone isn't enough to address a specific running process.
public struct FrontmostAppRef: Equatable, Sendable {
  public var bundleID: String?
  public var processIdentifier: pid_t

  public init(bundleID: String?, processIdentifier: pid_t) {
    self.bundleID = bundleID
    self.processIdentifier = processIdentifier
  }
}

/// Abstraction over "what app is frontmost right now," injected so
/// `FrontmostAppTracker` can be tested without touching real `NSWorkspace`
/// state — see coding-standards.md's testing rules ("mock side effects...
/// never touch real system state from a test").
///
/// Deliberately distinct from `Clipboard/ClipboardMonitor.FrontmostApplicationProviding`,
/// which answers a different question ("what app produced this clipboard
/// capture," for `PrivacyFilter` attribution) at a different point in time.
/// `FrontmostAppReferenceProviding` answers "which process should receive a
/// synthesized paste," and needs a process identifier in addition to a bundle
/// ID — the two protocols are kept separate rather than merged/reused.
public protocol FrontmostAppReferenceProviding: Sendable {
  func currentFrontmostAppRef() -> FrontmostAppRef?
}

// The production `NSWorkspace`-backed `FrontmostAppReferenceProviding` is
// `WorkspaceFrontmostAppReferenceProvider`
// (`Platform/macOS/WorkspaceFrontmostAppReferenceProvider.swift`) — moved out
// of this file (Linux port prep) since it's an AppKit implementation detail;
// this file stays platform-neutral (only `pid_t`, available via `Foundation`
// on every platform this compiles for — verified against `swift:6.0-jammy`).

/// Records "who was frontmost right before the picker was about to open," so
/// the paste step (`Paster`, plan task T15) knows which app to target once the
/// picker itself is shown.
///
/// The picker panel is deliberately non-activating (plan task T10), so it will
/// not itself become frontmost — but focus can still shift transiently before
/// the user makes a selection, so the target must be captured as early as
/// possible ("picker is about to open"), not read lazily at paste time.
@MainActor
public final class FrontmostAppTracker {
  private let provider: any FrontmostAppReferenceProviding
  private var recorded: FrontmostAppRef?

  public init(
    provider: any FrontmostAppReferenceProviding = PlatformDefaults.frontmostAppProvider
  ) {
    self.provider = provider
  }

  /// Records the provider's current frontmost app. Call this right before
  /// showing the picker panel. A second call before `consume()` overwrites
  /// the previous recording — last-recorded wins.
  public func record() {
    recorded = provider.currentFrontmostAppRef()
  }

  /// Returns the most recently recorded frontmost app and clears it, so a
  /// stale target from a previous picker session isn't reused for a later,
  /// unrelated paste.
  public func consume() -> FrontmostAppRef? {
    defer { recorded = nil }
    return recorded
  }
}

#if !os(macOS)
  extension PlatformDefaults {
    /// No frontmost-app tracking exists yet outside macOS — this always
    /// returns `nil`, so `Paster`/`FrontmostAppTracker` take the "no target
    /// available" path they already handle gracefully (clipboard-only
    /// paste, no synthesized keystroke — see `Paster.paste`'s doc comment).
    /// Never used in production; the Linux composition root always injects
    /// a real backend (see `PlatformDefaults.swift`'s doc comment).
    public static var frontmostAppProvider: any FrontmostAppReferenceProviding {
      NoOpFrontmostAppReferenceProvider()
    }
  }

  /// Portable no-op `FrontmostAppReferenceProviding` — see the
  /// `#if !os(macOS)` `PlatformDefaults.frontmostAppProvider` doc comment
  /// above.
  private struct NoOpFrontmostAppReferenceProvider: FrontmostAppReferenceProviding {
    func currentFrontmostAppRef() -> FrontmostAppRef? { nil }
  }
#endif
