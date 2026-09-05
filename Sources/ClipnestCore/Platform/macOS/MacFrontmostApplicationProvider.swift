import Foundation

#if os(macOS)
  import AppKit

  /// Production `FrontmostApplicationProviding` conformance backed by
  /// `NSWorkspace` — moved verbatim from `Clipboard/ClipboardMonitor.swift`
  /// by the Linux port (P2-A) and renamed from
  /// `WorkspaceFrontmostApplicationProvider` (no call site referenced the
  /// old name directly — verified — so this is a pure extraction, not a
  /// public-API break for any existing caller).
  public struct MacFrontmostApplicationProvider: FrontmostApplicationProviding {
    public init() {}

    public var frontmostBundleID: String? {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public var frontmostAppName: String? {
      NSWorkspace.shared.frontmostApplication?.localizedName
    }
  }

  extension PlatformDefaults {
    /// macOS's `FrontmostApplicationProviding` default — `NSWorkspace`-
    /// backed, byte-identical to the code this replaced. See
    /// `MacFrontmostApplicationProvider`.
    public static var frontmostApplicationProvider: any FrontmostApplicationProviding {
      MacFrontmostApplicationProvider()
    }
  }
#else
  extension PlatformDefaults {
    /// The non-Apple `FrontmostApplicationProviding` default. See
    /// `NullFrontmostApplicationProvider`'s doc comment.
    public static var frontmostApplicationProvider: any FrontmostApplicationProviding {
      NullFrontmostApplicationProvider()
    }
  }
#endif
