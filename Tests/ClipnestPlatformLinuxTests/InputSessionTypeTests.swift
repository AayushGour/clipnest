import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("SessionType")
struct SessionTypeTests {
  @Test("XDG_SESSION_TYPE=wayland is authoritative")
  func explicitWayland() {
    #expect(SessionType.detect(environment: ["XDG_SESSION_TYPE": "wayland"]) == .wayland)
  }

  @Test("XDG_SESSION_TYPE=x11 is authoritative")
  func explicitX11() {
    #expect(SessionType.detect(environment: ["XDG_SESSION_TYPE": "x11"]) == .x11)
  }

  @Test("XDG_SESSION_TYPE is case-insensitive")
  func caseInsensitive() {
    #expect(SessionType.detect(environment: ["XDG_SESSION_TYPE": "Wayland"]) == .wayland)
  }

  @Test("falls back to WAYLAND_DISPLAY when XDG_SESSION_TYPE is unset")
  func fallsBackToWaylandDisplay() {
    #expect(SessionType.detect(environment: ["WAYLAND_DISPLAY": "wayland-0"]) == .wayland)
  }

  @Test("falls back to DISPLAY when neither of the above is set")
  func fallsBackToDisplay() {
    #expect(SessionType.detect(environment: ["DISPLAY": ":0"]) == .x11)
  }

  @Test("an empty environment is unknown, not assumed X11")
  func emptyEnvironmentIsUnknown() {
    #expect(SessionType.detect(environment: [:]) == .unknown)
  }

  @Test("an unrecognized XDG_SESSION_TYPE value falls through to the other signals")
  func unrecognizedSessionTypeFallsThrough() {
    #expect(
      SessionType.detect(environment: ["XDG_SESSION_TYPE": "tty", "DISPLAY": ":0"]) == .x11)
  }
}
