import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// A scripted `ATSPIObjectCalling` — replies are looked up by the
/// outgoing message's `member` name, so tests read as "when GetSelection
/// is called, reply with (2, 5)" without any real D-Bus connection.
/// `@unchecked Sendable` is fine here: this is test-only support code, and
/// `ATSPITextAccessor`'s methods (synchronous, single-threaded per call in
/// every test below) never call into it concurrently.
private final class FakeATSPIObjectCalling: ATSPIObjectCalling, @unchecked Sendable {
  var repliesByMember: [String: DBusMessage] = [:]
  private(set) var calls: [DBusMessage] = []

  func call(_ message: DBusMessage, timeout: Duration) -> DBusMessage? {
    calls.append(message)
    guard let member = message.member else { return nil }
    return repliesByMember[member]
  }
}

private let testTarget = (busName: ":1.7", objectPath: "/org/a11y/atspi/accessible/3")

private func methodReturn(_ body: [DBusValue]) -> DBusMessage {
  DBusMessage(type: .methodReturn, serial: 1, replySerial: 1, body: body)
}

@Suite("ATSPITextAccessor")
struct ATSPITextAccessorTests {
  @Test("readSelectedText returns nil when nothing is focused")
  func readReturnsNilWithoutFocus() {
    let fake = FakeATSPIObjectCalling()
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { nil }, timeout: .milliseconds(1), nextSerial: { 1 })
    #expect(accessor.readSelectedText() == nil)
    #expect(fake.calls.isEmpty)
  }

  @Test("readSelectedText returns nil when there is no active selection")
  func readReturnsNilWithNoSelection() {
    let fake = FakeATSPIObjectCalling()
    fake.repliesByMember["GetNSelections"] = methodReturn([.int32(0)])
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { testTarget }, timeout: .milliseconds(1), nextSerial: { 1 })
    #expect(accessor.readSelectedText() == nil)
  }

  @Test("readSelectedText chains GetNSelections -> GetSelection -> GetText")
  func readChainsThreeCalls() {
    let fake = FakeATSPIObjectCalling()
    fake.repliesByMember["GetNSelections"] = methodReturn([.int32(1)])
    fake.repliesByMember["GetSelection"] = methodReturn([.structure([.int32(2), .int32(7)])])
    fake.repliesByMember["GetText"] = methodReturn([.string("lipnes")])
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { testTarget }, timeout: .milliseconds(1), nextSerial: { 1 })

    #expect(accessor.readSelectedText() == "lipnes")
    #expect(fake.calls.map(\.member) == ["GetNSelections", "GetSelection", "GetText"])
    let getTextCall = fake.calls[2]
    #expect(getTextCall.body == [.int32(2), .int32(7)])
    #expect(getTextCall.destination == testTarget.busName)
    #expect(getTextCall.path == testTarget.objectPath)
  }

  @Test("readSelectedText returns nil when any call in the chain times out (returns nil)")
  func readReturnsNilOnMidChainFailure() {
    let fake = FakeATSPIObjectCalling()
    fake.repliesByMember["GetNSelections"] = methodReturn([.int32(1)])
    fake.repliesByMember["GetSelection"] = methodReturn([.structure([.int32(0), .int32(3)])])
    // GetText deliberately left unanswered — simulates a timeout.
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { testTarget }, timeout: .milliseconds(1), nextSerial: { 1 })
    #expect(accessor.readSelectedText() == nil)
  }

  @Test("replaceSelectedText deletes the selection then inserts, using DeleteText+InsertText — never SetTextContents")
  func replaceDeletesThenInserts() {
    let fake = FakeATSPIObjectCalling()
    fake.repliesByMember["GetNSelections"] = methodReturn([.int32(1)])
    fake.repliesByMember["GetSelection"] = methodReturn([.structure([.int32(4), .int32(10)])])
    fake.repliesByMember["DeleteText"] = methodReturn([.boolean(true)])
    fake.repliesByMember["InsertText"] = methodReturn([.boolean(true)])
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { testTarget }, timeout: .milliseconds(1), nextSerial: { 1 })

    #expect(accessor.replaceSelectedText(with: "héllo") == true)
    #expect(fake.calls.map(\.member) == ["GetNSelections", "GetSelection", "DeleteText", "InsertText"])
    #expect(fake.calls.allSatisfy { $0.interface != "org.a11y.atspi.EditableText" || $0.member != "SetTextContents" })

    let deleteCall = fake.calls[2]
    #expect(deleteCall.body == [.int32(4), .int32(10)])

    // "héllo" is 5 characters but 6 UTF-8 bytes ('é' is 2 bytes) — the
    // InsertText length argument must be the BYTE count, and position must
    // be the selection's original character/scalar START offset (4), not
    // its end.
    let insertCall = fake.calls[3]
    #expect(insertCall.body == [.int32(4), .string("héllo"), .int32(6)])
  }

  @Test("replaceSelectedText returns false and never calls InsertText when DeleteText fails")
  func replaceStopsWhenDeleteFails() {
    let fake = FakeATSPIObjectCalling()
    fake.repliesByMember["GetNSelections"] = methodReturn([.int32(1)])
    fake.repliesByMember["GetSelection"] = methodReturn([.structure([.int32(0), .int32(2)])])
    fake.repliesByMember["DeleteText"] = methodReturn([.boolean(false)])
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { testTarget }, timeout: .milliseconds(1), nextSerial: { 1 })

    #expect(accessor.replaceSelectedText(with: "x") == false)
    #expect(!fake.calls.map(\.member).contains("InsertText"))
  }

  @Test("replaceSelectedText returns false when there is no selection to replace")
  func replaceFailsWithoutSelection() {
    let fake = FakeATSPIObjectCalling()
    fake.repliesByMember["GetNSelections"] = methodReturn([.int32(0)])
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { testTarget }, timeout: .milliseconds(1), nextSerial: { 1 })
    #expect(accessor.replaceSelectedText(with: "x") == false)
  }

  @Test("replaceSelectedText returns false when nothing is focused, without any call")
  func replaceFailsWithoutFocus() {
    let fake = FakeATSPIObjectCalling()
    let accessor = ATSPITextAccessor(
      caller: fake, focusedObject: { nil }, timeout: .milliseconds(1), nextSerial: { 1 })
    #expect(accessor.replaceSelectedText(with: "x") == false)
    #expect(fake.calls.isEmpty)
  }
}
