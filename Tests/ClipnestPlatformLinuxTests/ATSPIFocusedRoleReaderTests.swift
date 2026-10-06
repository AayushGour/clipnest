import Foundation
import Testing

@testable import ClipnestPlatformLinux

private final class FakeRoleCalling: ATSPIObjectCalling, @unchecked Sendable {
  var reply: DBusMessage?
  private(set) var calls: [DBusMessage] = []

  func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage? {
    calls.append(message)
    return reply
  }
}

private let focusedTarget = (busName: ":1.42", objectPath: "/org/a11y/atspi/accessible/9")

private func roleReply(_ role: UInt32) -> DBusMessage {
  DBusMessage(type: .methodReturn, serial: 1, replySerial: 1, body: [.uint32(role)])
}

private func makeReader(
  _ caller: FakeRoleCalling,
  focused: (busName: String, objectPath: String)? = focusedTarget
) -> ATSPIFocusedRoleReader {
  ATSPIFocusedRoleReader(caller: caller, focusedObject: { focused }, nextSerial: { 1 })
}

@Suite("ATSPIFocusedRoleReader")
struct ATSPIFocusedRoleReaderTests {
  @Test("The terminal role (60) is a terminal")
  func terminalRoleIsTerminal() {
    let caller = FakeRoleCalling()
    caller.reply = roleReply(ATSPIRole.terminal)
    #expect(makeReader(caller).isFocusedObjectTerminal())
  }

  @Test("Any other role is not a terminal")
  func otherRoleIsNotTerminal() {
    let caller = FakeRoleCalling()
    caller.reply = roleReply(61)
    #expect(!makeReader(caller).isFocusedObjectTerminal())
  }

  @Test("No reply is not a terminal")
  func missingReplyIsNotTerminal() {
    #expect(!makeReader(FakeRoleCalling()).isFocusedObjectTerminal())
  }

  @Test("No focused object is not a terminal, and makes no call")
  func noFocusedObjectMakesNoCall() {
    let caller = FakeRoleCalling()
    caller.reply = roleReply(ATSPIRole.terminal)
    #expect(!makeReader(caller, focused: nil).isFocusedObjectTerminal())
    #expect(caller.calls.isEmpty)
  }

  @Test("Asks the focused object's Accessible interface for GetRole")
  func asksFocusedObjectForRole() {
    let caller = FakeRoleCalling()
    _ = makeReader(caller).isFocusedObjectTerminal()
    #expect(caller.calls.count == 1)
    #expect(caller.calls.first?.destination == focusedTarget.busName)
    #expect(caller.calls.first?.path == focusedTarget.objectPath)
    #expect(caller.calls.first?.interface == "org.a11y.atspi.Accessible")
    #expect(caller.calls.first?.member == "GetRole")
  }

  @Test("The accessible-terminal marker selects Ctrl+Shift+V")
  func accessibleTerminalMarkerSelectsShiftedPaste() {
    #expect(
      TerminalAppRegistry.modifiers(
        forAppIdentifier: TerminalAppRegistry.accessibleTerminalIdentifier) == [.control, .shift])
  }
}
