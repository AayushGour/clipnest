import Foundation

/// P2-A (Linux port): the non-Apple default `FrontmostApplicationProviding`
/// conformance. Always reports `nil` for both properties — "never used in
/// production" (`PlatformDefaults.swift`'s documented convention for
/// portable no-op defaults): the Linux composition root always injects a
/// real frontmost-window backend (e.g. querying the window manager/
/// compositor), this exists only so `ClipboardMonitor.init`'s
/// `frontmostApplicationProvider` parameter has *some* non-Apple default to
/// compile against. A `nil` `sourceBundleID` never trips
/// `PrivacyFilter.shouldCapture`'s exclusion checks (they only ever
/// *exclude* on a known bundle ID match), so this is a safe inert default,
/// not a silent privacy gap.
public struct NullFrontmostApplicationProvider: FrontmostApplicationProviding {
  public init() {}

  public var frontmostBundleID: String? { nil }
  public var frontmostAppName: String? { nil }
}
