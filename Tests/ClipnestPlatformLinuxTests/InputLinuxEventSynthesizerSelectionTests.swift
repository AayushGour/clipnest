import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("LinuxEventSynthesizerSelection")
struct LinuxEventSynthesizerSelectionTests {
  @Test("uinput wins whenever available, regardless of session type")
  func uinputTakesPriority() {
    #expect(
      LinuxEventSynthesizerSelection.choose(
        uinputAvailable: true, sessionType: .wayland, xtestAvailable: true) == .uinput)
    #expect(
      LinuxEventSynthesizerSelection.choose(
        uinputAvailable: true, sessionType: .x11, xtestAvailable: false) == .uinput)
  }

  @Test("XTEST is chosen only on X11 when uinput is unavailable")
  func xtestOnlyOnX11() {
    #expect(
      LinuxEventSynthesizerSelection.choose(
        uinputAvailable: false, sessionType: .x11, xtestAvailable: true) == .xtest)
  }

  @Test("XTEST is never chosen on Wayland, even if reported available")
  func xtestNeverOnWayland() {
    #expect(
      LinuxEventSynthesizerSelection.choose(
        uinputAvailable: false, sessionType: .wayland, xtestAvailable: true) == .clipboardOnly)
  }

  @Test("XTEST is never chosen when session type is unknown (fail closed)")
  func xtestNeverOnUnknownSession() {
    #expect(
      LinuxEventSynthesizerSelection.choose(
        uinputAvailable: false, sessionType: .unknown, xtestAvailable: true) == .clipboardOnly)
  }

  @Test("falls back to clipboard-only when nothing is available")
  func fallsBackToClipboardOnly() {
    #expect(
      LinuxEventSynthesizerSelection.choose(
        uinputAvailable: false, sessionType: .x11, xtestAvailable: false) == .clipboardOnly)
  }
}
