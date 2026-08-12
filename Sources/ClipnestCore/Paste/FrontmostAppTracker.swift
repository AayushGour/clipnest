import AppKit
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

/// Production `FrontmostAppReferenceProviding` backed by `NSWorkspace`.
public struct WorkspaceFrontmostAppReferenceProvider: FrontmostAppReferenceProviding {
  public init() {}

  public func currentFrontmostAppRef() -> FrontmostAppRef? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return FrontmostAppRef(bundleID: app.bundleIdentifier, processIdentifier: app.processIdentifier)
  }
}

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
    provider: any FrontmostAppReferenceProviding = WorkspaceFrontmostAppReferenceProvider()
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
