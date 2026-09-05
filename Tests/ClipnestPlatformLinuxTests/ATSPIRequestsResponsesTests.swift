import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("ATSPIRequests")
struct ATSPIRequestsTests {
  @Test("getSelection targets the Text interface with the selection index as its only arg")
  func getSelectionShape() {
    let message = ATSPIRequests.getSelection(
      busName: ":1.5", objectPath: "/org/a11y/atspi/accessible/1", selectionIndex: 0, serial: 9)
    #expect(message.destination == ":1.5")
    #expect(message.path == "/org/a11y/atspi/accessible/1")
    #expect(message.interface == ATSPIInterface.text)
    #expect(message.member == "GetSelection")
    #expect(message.body == [.int32(0)])
  }

  @Test("insertText's length arg is the UTF-8 BYTE count, not the character count")
  func insertTextUsesByteLength() {
    let text = "héllo"  // 5 characters, 6 UTF-8 bytes.
    let message = ATSPIRequests.insertText(
      busName: ":1.5", objectPath: "/a", position: 3, text: text, serial: 1)
    #expect(message.interface == ATSPIInterface.editableText)
    #expect(message.member == "InsertText")
    #expect(message.body == [.int32(3), .string(text), .int32(6)])
  }

  @Test("deleteText targets EditableText with start/end as plain int32 args")
  func deleteTextShape() {
    let message = ATSPIRequests.deleteText(
      busName: ":1.5", objectPath: "/a", start: 2, end: 8, serial: 1)
    #expect(message.interface == ATSPIInterface.editableText)
    #expect(message.member == "DeleteText")
    #expect(message.body == [.int32(2), .int32(8)])
  }

  @Test("getAddress targets org.a11y.Bus at /org/a11y/bus")
  func getAddressShape() {
    let message = ATSPIRequests.getAddress(serial: 1)
    #expect(message.destination == "org.a11y.Bus")
    #expect(message.path == "/org/a11y/bus")
    #expect(message.interface == "org.a11y.Bus")
    #expect(message.member == "GetAddress")
  }

  @Test("registerFocusEvent sends the legacy interface:signal:detail event string")
  func registerFocusEventShape() {
    let message = ATSPIRequests.registerFocusEvent(serial: 1)
    #expect(message.destination == ATSPIBusName.registry)
    #expect(message.path == ATSPIPath.registry)
    #expect(message.body == [.string("object:state-changed:focused")])
  }

  @Test("addFocusMatch targets the bus daemon's own AddMatch with a filtering rule string")
  func addFocusMatchShape() {
    let message = ATSPIRequests.addFocusMatch(serial: 1)
    #expect(message.destination == "org.freedesktop.DBus")
    #expect(message.member == "AddMatch")
    #expect(
      message.body == [.string("interface='org.a11y.atspi.Event.Object',member='StateChanged'")])
  }
}

@Suite("ATSPIResponses")
struct ATSPIResponsesTests {
  @Test("parses an int32 reply (GetNSelections' shape)")
  func parsesInt32Reply() {
    let reply = DBusMessage(type: .methodReturn, serial: 2, replySerial: 1, body: [.int32(1)])
    #expect(ATSPIResponses.parseInt32Reply(reply) == 1)
  }

  @Test("parses a (ii) struct reply (GetSelection's shape)")
  func parsesSelectionReply() {
    let reply = DBusMessage(
      type: .methodReturn, serial: 2, replySerial: 1, body: [.structure([.int32(3), .int32(9)])])
    let result = ATSPIResponses.parseSelectionReply(reply)
    #expect(result?.start == 3)
    #expect(result?.end == 9)
  }

  @Test("parses a string reply (GetText/GetAddress's shape)")
  func parsesStringReply() {
    let reply = DBusMessage(
      type: .methodReturn, serial: 2, replySerial: 1, body: [.string("hello")])
    #expect(ATSPIResponses.parseStringReply(reply) == "hello")
  }

  @Test("parses a boolean reply (DeleteText/InsertText's shape)")
  func parsesBooleanReply() {
    let reply = DBusMessage(type: .methodReturn, serial: 2, replySerial: 1, body: [.boolean(true)])
    #expect(ATSPIResponses.parseBooleanReply(reply) == true)
  }

  @Test("an ERROR reply never parses as a success value")
  func errorReplyNeverParsesAsSuccess() {
    let errorReply = DBusMessage(
      type: .error, serial: 2, replySerial: 1, errorName: "org.freedesktop.DBus.Error.Failed",
      body: [.boolean(true)])
    #expect(ATSPIResponses.parseBooleanReply(errorReply) == nil)
    #expect(ATSPIResponses.parseInt32Reply(errorReply) == nil)
  }

  @Test("a property Get reply unwraps its VARIANT")
  func parsesBooleanPropertyReply() {
    let reply = DBusMessage(
      type: .methodReturn, serial: 2, replySerial: 1, body: [.variant(.boolean(true))])
    #expect(ATSPIResponses.parseBooleanPropertyReply(reply) == true)
  }
}
