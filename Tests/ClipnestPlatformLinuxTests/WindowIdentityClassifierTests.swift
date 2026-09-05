import Testing

@testable import ClipnestPlatformLinux

@Suite("WindowIdentityClassifier")
struct WindowIdentityClassifierTests {
  @Test("Nil _NET_ACTIVE_WINDOW classifies as .none")
  func nilActiveWindowIsNone() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: nil, className: nil, processID: nil, gtkApplicationID: nil, windowName: nil)
    #expect(outcome == .none)
  }

  @Test("_NET_ACTIVE_WINDOW == 0 (X11 None) classifies as .none — nothing focused")
  func zeroActiveWindowIsNone() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: 0, className: nil, processID: nil, gtkApplicationID: nil, windowName: nil)
    #expect(outcome == .none)
  }

  @Test(
    """
    A real, non-zero active window with EVERY identity property empty is the mutter \
    no_focus_window shape — a native-Wayland app is focused, identity unavailable. \
    Distinct from .none.
    """
  )
  func realWindowWithNoIdentityIsWaylandFocusUnavailable() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: 12345, className: nil, processID: nil, gtkApplicationID: nil,
      windowName: nil)
    #expect(outcome == .waylandFocusUnavailable)
    #expect(outcome != .none)
  }

  @Test("A real window with a readable WM_CLASS is .identified")
  func realWindowWithClassNameIsIdentified() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: 12345, className: "Firefox", processID: nil, gtkApplicationID: nil,
      windowName: nil)
    guard case .identified(let identity) = outcome else {
      Issue.record("expected .identified, got \(outcome)")
      return
    }
    #expect(identity.className == "Firefox")
  }

  @Test("A real window identified only by _NET_WM_PID (no WM_CLASS) is still .identified")
  func identifiedByPIDAlone() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: 999, className: nil, processID: 4242, gtkApplicationID: nil,
      windowName: nil)
    guard case .identified(let identity) = outcome else {
      Issue.record("expected .identified, got \(outcome)")
      return
    }
    #expect(identity.processID == 4242)
  }

  @Test("A real window identified only by _GTK_APPLICATION_ID is .identified")
  func identifiedByGtkApplicationIDAlone() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: 999, className: nil, processID: nil,
      gtkApplicationID: "org.gnome.TextEditor", windowName: nil)
    guard case .identified(let identity) = outcome else {
      Issue.record("expected .identified, got \(outcome)")
      return
    }
    #expect(identity.gtkApplicationID == "org.gnome.TextEditor")
  }

  @Test("A real window identified only by _NET_WM_NAME is .identified")
  func identifiedByWindowNameAlone() {
    let outcome = WindowIdentityClassifier.classify(
      activeWindowID: 999, className: nil, processID: nil, gtkApplicationID: nil,
      windowName: "Untitled Document")
    guard case .identified(let identity) = outcome else {
      Issue.record("expected .identified, got \(outcome)")
      return
    }
    #expect(identity.windowName == "Untitled Document")
  }
}
