import Testing

@testable import ClipnestPlatformLinux

/// Fully in-memory `X11WindowIdentityQuerying` fake — no Xlib, no display.
private final class FakeX11WindowIdentityQuerying: X11WindowIdentityQuerying, @unchecked Sendable {
  var activeWindow: UInt64?
  var classNames: [UInt64: String] = [:]
  var pids: [UInt64: Int32] = [:]
  var gtkIDs: [UInt64: String] = [:]
  var names: [UInt64: String] = [:]
  private(set) var propertyQueryCallCount = 0

  func activeWindowID() -> UInt64? { activeWindow }

  func className(of window: UInt64) -> String? {
    propertyQueryCallCount += 1
    return classNames[window]
  }

  func processID(of window: UInt64) -> Int32? {
    propertyQueryCallCount += 1
    return pids[window]
  }

  func gtkApplicationID(of window: UInt64) -> String? {
    propertyQueryCallCount += 1
    return gtkIDs[window]
  }

  func windowName(of window: UInt64) -> String? {
    propertyQueryCallCount += 1
    return names[window]
  }
}

@Suite("LinuxFrontmostApplicationProvider")
struct LinuxFrontmostApplicationProviderTests {
  @Test("Nothing focused (no _NET_ACTIVE_WINDOW) reports nil identity and .none")
  func nothingFocusedReportsNil() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = nil
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.frontmostBundleID == nil)
    #expect(provider.frontmostAppName == nil)
    #expect(provider.lastOutcome == .none)
  }

  @Test("_NET_ACTIVE_WINDOW == 0 (X11 None) never triggers identity property reads")
  func zeroActiveWindowSkipsPropertyQueries() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = 0
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.lastOutcome == .none)
    #expect(querying.propertyQueryCallCount == 0)
  }

  @Test(
    """
    A real active window with every identity property empty reports nil identity but a \
    DISTINCT outcome from "nothing focused" — the mutter no_focus_window shape.
    """
  )
  func waylandFocusedAppReportsDistinctOutcome() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = 555
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.frontmostBundleID == nil)
    #expect(provider.frontmostAppName == nil)
    #expect(provider.lastOutcome == .waylandFocusUnavailable)
    #expect(provider.lastOutcome != .none)
  }

  @Test("Prefers _GTK_APPLICATION_ID over WM_CLASS for frontmostBundleID")
  func prefersGtkApplicationIDForBundleID() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = 1
    querying.classNames[1] = "Gnome-text-editor"
    querying.gtkIDs[1] = "org.gnome.TextEditor"
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.frontmostBundleID == "org.gnome.TextEditor")
  }

  @Test("Falls back to WM_CLASS for frontmostBundleID when no _GTK_APPLICATION_ID is set")
  func fallsBackToClassNameForBundleID() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = 1
    querying.classNames[1] = "Firefox"
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.frontmostBundleID == "Firefox")
  }

  @Test("frontmostAppName prefers WM_CLASS (a short program name) over the window title")
  func appNamePrefersClassNameOverWindowTitle() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = 1
    querying.classNames[1] = "firefox"
    querying.names[1] = "My Document - Mozilla Firefox"
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.frontmostAppName == "firefox")
  }

  @Test("frontmostAppName falls back to the window title when WM_CLASS is unavailable")
  func appNameFallsBackToWindowTitle() {
    let querying = FakeX11WindowIdentityQuerying()
    querying.activeWindow = 1
    querying.names[1] = "Untitled Document"
    let provider = LinuxFrontmostApplicationProvider(querying: querying)

    #expect(provider.frontmostAppName == "Untitled Document")
  }
}
