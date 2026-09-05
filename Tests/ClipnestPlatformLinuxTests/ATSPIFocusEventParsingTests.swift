import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("ATSPIFocusEventParsing")
struct ATSPIFocusEventParsingTests {
  private func focusedSignal(sender: String? = ":1.42", path: String? = "/org/a11y/atspi/accessible/1")
    -> DBusMessage
  {
    DBusMessage(
      type: .signal, serial: 1, path: path, interface: ATSPIInterface.event,
      member: ATSPIMember.stateChanged, sender: sender,
      body: [.string("focused"), .int32(1), .int32(0), .variant(.int32(0)), .array([])])
  }

  @Test("extracts (sender, path) from a genuine focus-gained StateChanged signal")
  func extractsFocusedTarget() {
    let result = ATSPIFocusEventParsing.focusedTarget(from: focusedSignal())
    #expect(result?.busName == ":1.42")
    #expect(result?.objectPath == "/org/a11y/atspi/accessible/1")
  }

  @Test("ignores a focus-LOST event (enabled == 0)")
  func ignoresFocusLost() {
    let message = DBusMessage(
      type: .signal, serial: 1, path: "/a", interface: ATSPIInterface.event,
      member: ATSPIMember.stateChanged, sender: ":1.42",
      body: [.string("focused"), .int32(0), .int32(0), .variant(.int32(0)), .array([])])
    #expect(ATSPIFocusEventParsing.focusedTarget(from: message) == nil)
  }

  @Test("ignores a StateChanged signal for a different state (e.g. \"selected\")")
  func ignoresOtherStates() {
    let message = DBusMessage(
      type: .signal, serial: 1, path: "/a", interface: ATSPIInterface.event,
      member: ATSPIMember.stateChanged, sender: ":1.42",
      body: [.string("selected"), .int32(1), .int32(0), .variant(.int32(0)), .array([])])
    #expect(ATSPIFocusEventParsing.focusedTarget(from: message) == nil)
  }

  @Test("ignores a message on a different interface/member entirely")
  func ignoresUnrelatedMessages() {
    let methodReturn = DBusMessage(type: .methodReturn, serial: 1, replySerial: 1, body: [])
    #expect(ATSPIFocusEventParsing.focusedTarget(from: methodReturn) == nil)
  }

  @Test("returns nil when sender or path header fields are missing")
  func returnsNilWithoutSenderOrPath() {
    #expect(ATSPIFocusEventParsing.focusedTarget(from: focusedSignal(sender: nil)) == nil)
    #expect(ATSPIFocusEventParsing.focusedTarget(from: focusedSignal(path: nil)) == nil)
  }
}
