#if os(macOS)
  import AppKit
  import Foundation

  /// Production `FrontmostAppReferenceProviding` backed by `NSWorkspace`.
  public struct WorkspaceFrontmostAppReferenceProvider: FrontmostAppReferenceProviding {
    public init() {}

    public func currentFrontmostAppRef() -> FrontmostAppRef? {
      guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
      return FrontmostAppRef(
        bundleID: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }
  }

  extension PlatformDefaults {
    /// The production `FrontmostAppReferenceProviding` on macOS. See
    /// `PlatformDefaults`'s own doc comment for why this is a static member
    /// here rather than a literal default-argument value in
    /// `Paster.swift`/`FrontmostAppTracker.swift`.
    public static var frontmostAppProvider: any FrontmostAppReferenceProviding {
      WorkspaceFrontmostAppReferenceProvider()
    }
  }
#endif
