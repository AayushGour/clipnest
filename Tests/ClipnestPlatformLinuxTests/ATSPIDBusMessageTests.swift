import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("DBusMessage")
struct DBusMessageTests {
  @Test("round-trips a method call with a simple int32 body (GetSelection-shaped)")
  func roundTripsMethodCall() {
    let message = DBusMessage(
      type: .methodCall, serial: 7, path: "/org/a11y/atspi/accessible/42",
      interface: "org.a11y.atspi.Text", member: "GetSelection", destination: ":1.99",
      body: [.int32(0)])
    let encoded = message.encoded()
    guard let (decoded, consumed) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode")
      return
    }
    #expect(consumed == encoded.count)
    #expect(decoded.type == .methodCall)
    #expect(decoded.serial == 7)
    #expect(decoded.path == "/org/a11y/atspi/accessible/42")
    #expect(decoded.interface == "org.a11y.atspi.Text")
    #expect(decoded.member == "GetSelection")
    #expect(decoded.destination == ":1.99")
    #expect(decoded.body == [.int32(0)])
  }

  @Test("round-trips a method return with a struct body ((ii) — GetSelection's reply shape)")
  func roundTripsStructBody() {
    let message = DBusMessage(
      type: .methodReturn, serial: 12, replySerial: 7, body: [.structure([.int32(3), .int32(9)])])
    let encoded = message.encoded()
    guard let (decoded, _) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode")
      return
    }
    #expect(decoded.replySerial == 7)
    #expect(decoded.body == [.structure([.int32(3), .int32(9)])])
  }

  @Test("round-trips a signal with sender/path header fields and a siiva{sv}-shaped body")
  func roundTripsSignalWithSenderAndBody() {
    let message = DBusMessage(
      type: .signal, serial: 3, path: "/org/a11y/atspi/accessible/7",
      interface: "org.a11y.atspi.Event.Object", member: "StateChanged", sender: ":1.55",
      body: [
        .string("focused"), .int32(1), .int32(0), .variant(.int32(0)),
        .array([.dictEntry(.string("k"), .variant(.string("v")))]),
      ])
    let encoded = message.encoded()
    guard let (decoded, consumed) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode")
      return
    }
    #expect(consumed == encoded.count)
    #expect(decoded.sender == ":1.55")
    #expect(decoded.path == "/org/a11y/atspi/accessible/7")
    #expect(decoded.interface == "org.a11y.atspi.Event.Object")
    #expect(decoded.member == "StateChanged")
    #expect(decoded.body.count == 5)
    #expect(decoded.body[0] == .string("focused"))
    #expect(decoded.body[1] == .int32(1))
  }

  @Test("round-trips a message with no body at all (GetNSelections-shaped call)")
  func roundTripsEmptyBody() {
    let message = DBusMessage(
      type: .methodCall, serial: 1, path: "/a", interface: "org.a11y.atspi.Text",
      member: "GetNSelections", destination: ":1.1")
    let encoded = message.encoded()
    guard let (decoded, _) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode")
      return
    }
    #expect(decoded.body.isEmpty)
    #expect(decoded.signature == nil)
  }

  @Test("decode returns nil on a truncated buffer, so the transport knows to read more")
  func returnsNilOnTruncatedBuffer() {
    let message = DBusMessage(
      type: .methodCall, serial: 1, path: "/a", interface: "org.a11y.atspi.Text",
      member: "GetText", destination: ":1.1", body: [.int32(0), .int32(10)])
    let encoded = message.encoded()
    let truncated = Array(encoded.prefix(encoded.count - 1))
    #expect(DBusMessage.decode(truncated) == nil)
  }

  @Test("decode returns nil on fewer than 16 bytes")
  func returnsNilOnTooShortBuffer() {
    #expect(DBusMessage.decode([0, 1, 2]) == nil)
  }

  @Test("consumedByteCount lets a stream reader locate the NEXT message")
  func consumedByteCountAllowsFraming() {
    let first = DBusMessage(type: .methodCall, serial: 1, path: "/a", member: "M1")
    let second = DBusMessage(type: .methodCall, serial: 2, path: "/b", member: "M2")
    let combined = first.encoded() + second.encoded()
    guard let (decodedFirst, consumed) = DBusMessage.decode(combined) else {
      Issue.record("failed to decode first message")
      return
    }
    #expect(decodedFirst.serial == 1)
    let remaining = Array(combined[consumed...])
    guard let (decodedSecond, _) = DBusMessage.decode(remaining) else {
      Issue.record("failed to decode second message")
      return
    }
    #expect(decodedSecond.serial == 2)
  }
}
