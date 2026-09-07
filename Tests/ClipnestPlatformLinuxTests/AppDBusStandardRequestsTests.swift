import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("DBusStandardRequests / DBusStandardResponses")
struct AppDBusStandardRequestsTests {
  @Test("requestName() carries the name and flags verbatim")
  func requestNameMessageShape() {
    let message = DBusStandardRequests.requestName(
      "app.clipnest.Clipnest", flags: 0x4, serial: 2)
    #expect(message.member == "RequestName")
    #expect(message.body == [.string("app.clipnest.Clipnest"), .uint32(0x4)])
  }

  @Test("nameHasOwner()/getNameOwner() carry the queried name")
  func nameHasOwnerAndGetNameOwnerShapes() {
    let hasOwner = DBusStandardRequests.nameHasOwner("app.clipnest.ShellHelper", serial: 3)
    #expect(hasOwner.member == "NameHasOwner")
    #expect(hasOwner.body == [.string("app.clipnest.ShellHelper")])

    let getOwner = DBusStandardRequests.getNameOwner("app.clipnest.ShellHelper", serial: 4)
    #expect(getOwner.member == "GetNameOwner")
    #expect(getOwner.body == [.string("app.clipnest.ShellHelper")])
  }

  @Test("addNameOwnerChangedMatch scopes the rule to the given name via arg0=")
  func addNameOwnerChangedMatchScopesToName() {
    let message = DBusStandardRequests.addNameOwnerChangedMatch(
      forName: "app.clipnest.ShellHelper", serial: 5)
    #expect(message.member == "AddMatch")
    guard case .string(let rule)? = message.body.first else {
      Issue.record("expected the match rule string")
      return
    }
    #expect(rule.contains("member='NameOwnerChanged'"))
    #expect(rule.contains("arg0='app.clipnest.ShellHelper'"))
  }

  @Test("parseRequestNameReply decodes every known reply code")
  func parseRequestNameReplyDecodesKnownCodes() {
    #expect(
      DBusStandardResponses.parseRequestNameReply(fakeMethodReturn(body: [.uint32(1)]))
        == .primaryOwner)
    #expect(
      DBusStandardResponses.parseRequestNameReply(fakeMethodReturn(body: [.uint32(2)]))
        == .inQueue)
    #expect(
      DBusStandardResponses.parseRequestNameReply(fakeMethodReturn(body: [.uint32(3)])) == .exists)
    #expect(
      DBusStandardResponses.parseRequestNameReply(fakeMethodReturn(body: [.uint32(4)]))
        == .alreadyOwner)
  }

  @Test("parseRequestNameReply rejects a non-methodReturn or wrong-typed body")
  func parseRequestNameReplyRejectsWrongShapes() {
    let errorReply = DBusMessage(type: .error, serial: 1, errorName: "some.Error")
    #expect(DBusStandardResponses.parseRequestNameReply(errorReply) == nil)
    #expect(
      DBusStandardResponses.parseRequestNameReply(fakeMethodReturn(body: [.string("oops")]))
        == nil)
  }

  @Test("parseNameOwnerChanged extracts name/oldOwner/newOwner from the signal body")
  func parseNameOwnerChangedExtractsFields() {
    let signal = DBusMessage(
      type: .signal, serial: 1, member: "NameOwnerChanged",
      body: [.string("app.clipnest.ShellHelper"), .string(""), .string(":1.42")])
    let parsed = DBusStandardResponses.parseNameOwnerChanged(signal)
    #expect(parsed?.name == "app.clipnest.ShellHelper")
    #expect(parsed?.oldOwner == "")
    #expect(parsed?.newOwner == ":1.42")
  }
}
