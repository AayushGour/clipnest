// FakeProviders.swift
//
// Minimal fakes for the other injectable protocols `ClipboardMonitor`/
// `Paster` take, so the harness never touches real `NSWorkspace`/`CGEvent`
// state — same "mock side effects, never touch real system state" rule
// coding-standards.md holds `ClipnestCoreTests` to, applied here too.
import ClipnestCore
import Foundation

/// Fixed "source app" for every capture — `ClipboardMonitor`'s
/// `FrontmostApplicationProviding` (capture-attribution side).
struct FakeFrontmostApplicationProvider: FrontmostApplicationProviding {
  let bundleID: String?
  let appName: String?

  var frontmostBundleID: String? { bundleID }
  var frontmostAppName: String? { appName }
}

/// Fixed "paste target" — `Paster`'s `FrontmostAppReferenceProviding`
/// (paste-targeting side). Deliberately returns the SAME target on every
/// call so `Paster.isStillFrontmost` never spuriously fails inside the
/// harness (a real focus change mid-`synthesisDelay` is a separate concern
/// from what this harness stresses).
final class FakeFrontmostAppReferenceProvider: FrontmostAppReferenceProviding, @unchecked Sendable
{
  private let lock = NSLock()
  private var _ref: FrontmostAppRef?

  init(_ ref: FrontmostAppRef?) {
    self._ref = ref
  }

  func currentFrontmostAppRef() -> FrontmostAppRef? {
    lock.lock()
    defer { lock.unlock() }
    return _ref
  }

  func setRef(_ ref: FrontmostAppRef?) {
    lock.lock()
    _ref = ref
    lock.unlock()
  }
}

/// Records synthesized-paste attempts WITHOUT ever posting a real `CGEvent`
/// — the harness must never inject a real keystroke into whatever app
/// happens to hold focus on this machine (other agents' work may be in
/// flight in other windows).
final class FakeEventSynthesizer: EventSynthesizing, @unchecked Sendable {
  private let lock = NSLock()
  private var _callCount = 0
  private var _lastTarget: FrontmostAppRef?

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _callCount
  }

  func synthesizeCommandV(targeting app: FrontmostAppRef) throws {
    lock.lock()
    _callCount += 1
    _lastTarget = app
    lock.unlock()
  }
}
