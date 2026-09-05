import ClipnestCore
import ClipnestPlatformLinux
import Foundation

/// The real, composition-root-injected `FrontmostAppReferenceProviding` —
/// see `ClipnestCore.FrontmostAppTracker`'s `#if !os(macOS)`
/// `PlatformDefaults.frontmostAppProvider` doc comment: "the Linux
/// composition root always injects a real backend." `Paster` needs a
/// process identifier (not just a bundle-ID-shaped string) to target a
/// synthesized paste at a specific process — reuses the exact same
/// `X11WindowIdentityQuerying` seam and `WindowIdentityClassifier` pure
/// logic `ClipnestPlatformLinux.LinuxFrontmostApplicationProvider` already
/// built for the read-only "what produced this capture" question, just
/// surfaced through the different protocol shape `Paster`'s targeting
/// needs.
public struct LinuxFrontmostAppReferenceProvider: FrontmostAppReferenceProviding {
  private let querying: any X11WindowIdentityQuerying

  public init(querying: any X11WindowIdentityQuerying = X11ClipboardConnection.shared) {
    self.querying = querying
  }

  public func currentFrontmostAppRef() -> FrontmostAppRef? {
    let windowID = querying.activeWindowID()
    let queryableWindowID = (windowID != nil && windowID != 0) ? windowID : nil

    let className = queryableWindowID.flatMap(querying.className(of:))
    let processID = queryableWindowID.flatMap(querying.processID(of:))
    let gtkApplicationID = queryableWindowID.flatMap(querying.gtkApplicationID(of:))
    let windowName = queryableWindowID.flatMap(querying.windowName(of:))

    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: windowID, className: className, processID: processID,
      gtkApplicationID: gtkApplicationID, windowName: windowName)
    guard case .identified(let identity) = outcome, let processID = identity.processID else {
      return nil
    }
    return FrontmostAppRef(
      bundleID: identity.gtkApplicationID ?? identity.className,
      processIdentifier: pid_t(processID))
  }
}
