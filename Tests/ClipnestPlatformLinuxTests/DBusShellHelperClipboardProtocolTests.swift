import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

/// Pure request/response coverage for the five `app.clipnest.ShellHelper1`
/// clipboard-payload members (task P8-C): `SetClipboardWatch`,
/// `GetClipboardMimeTypes`, `ReadClipboard`, `SetClipboard`, and the
/// `ClipboardChanged` signal. No connection, no fake, no real fd — these
/// builders/parsers only ever see the WIRE shape (a `.unixFD` INDEX, never
/// a real descriptor), mirroring every other `ShellHelperRequests`/
/// `ShellHelperResponses` test's shape in this file's sibling
/// `AppShellHelperProtocolTests.swift`.
@Suite("ShellHelperRequests/Responses — clipboard payload members")
struct DBusShellHelperClipboardProtocolTests {
  @Test("setClipboardWatch sends both boolean flags to the right member")
  func setClipboardWatchBuildsCorrectMessage() {
    let message = ShellHelperRequests.setClipboardWatch(
      enable: true, includePrimary: false, serial: 1)
    #expect(message.member == "SetClipboardWatch")
    #expect(message.interface == ShellHelperName.interface)
    #expect(message.destination == ShellHelperName.busName)
    #expect(message.body == [.boolean(true), .boolean(false)])
  }

  @Test("getClipboardMimeTypes sends the raw selection ordinal")
  func getClipboardMimeTypesBuildsCorrectMessage() {
    let message = ShellHelperRequests.getClipboardMimeTypes(selection: .clipboard, serial: 2)
    #expect(message.member == "GetClipboardMimeTypes")
    #expect(message.body == [.uint32(ShellHelperClipboardSelection.clipboard.rawValue)])
  }

  @Test("parseGetClipboardMimeTypes reads mimeTypes + clipboardSerial from a valid reply")
  func parseGetClipboardMimeTypesReadsValidReply() {
    let reply = DBusMessage(
      type: .methodReturn, serial: 1, replySerial: 2,
      body: [.array([.string("text/plain"), .string("image/png")]), .uint64(42)])
    let result = ShellHelperResponses.parseGetClipboardMimeTypes(reply)
    #expect(result?.mimeTypes == ["text/plain", "image/png"])
    #expect(result?.clipboardSerial == 42)
  }

  @Test("parseGetClipboardMimeTypes rejects a malformed reply")
  func parseGetClipboardMimeTypesRejectsMalformedReply() {
    let reply = DBusMessage(type: .methodReturn, serial: 1, replySerial: 2, body: [.uint64(42)])
    #expect(ShellHelperResponses.parseGetClipboardMimeTypes(reply) == nil)
  }

  @Test("readClipboard sends selection + mimetype, no fd attached on the request")
  func readClipboardBuildsCorrectMessage() {
    let message = ShellHelperRequests.readClipboard(
      selection: .primary, mimetype: "text/plain", serial: 3)
    #expect(message.member == "ReadClipboard")
    #expect(
      message.body == [
        .uint32(ShellHelperClipboardSelection.primary.rawValue), .string("text/plain"),
      ]
    )
    #expect(message.unixFileDescriptorCount == 0, "the request carries no fd — only the reply does")
  }

  @Test("isReadClipboardReplyShapeValid accepts a single .unixFD body and rejects anything else")
  func readClipboardReplyShapeValidation() {
    let valid = DBusMessage(type: .methodReturn, serial: 1, replySerial: 3, body: [.unixFD(0)])
    #expect(ShellHelperResponses.isReadClipboardReplyShapeValid(valid))

    let wrongType = DBusMessage(
      type: .methodReturn, serial: 1, replySerial: 3, body: [.string("x")])
    #expect(!ShellHelperResponses.isReadClipboardReplyShapeValid(wrongType))

    let notAReply = DBusMessage(type: .methodCall, serial: 1, body: [.unixFD(0)])
    #expect(!ShellHelperResponses.isReadClipboardReplyShapeValid(notAReply))

    let empty = DBusMessage(type: .methodReturn, serial: 1, replySerial: 3)
    #expect(!ShellHelperResponses.isReadClipboardReplyShapeValid(empty))
  }

  @Test("setClipboard attaches the fd at wire index 0 and declares one attached descriptor")
  func setClipboardBuildsCorrectMessage() {
    let message = ShellHelperRequests.setClipboard(mimetype: "text/plain", serial: 4)
    #expect(message.member == "SetClipboard")
    #expect(message.body == [.string("text/plain"), .unixFD(0)])
  }

  @Test("parseSetClipboardReply reads the returned clipboard serial")
  func parseSetClipboardReplyReadsSerial() {
    let reply = DBusMessage(type: .methodReturn, serial: 1, replySerial: 4, body: [.uint64(9)])
    #expect(ShellHelperResponses.parseSetClipboardReply(reply) == 9)
  }

  @Test("parseClipboardChanged reads selection/serial/mimeTypes/ownerIsUs, ignoring source")
  func parseClipboardChangedReadsSignal() {
    let signal = DBusMessage(
      type: .signal, serial: 1, interface: ShellHelperName.interface,
      member: "ClipboardChanged",
      body: [
        .uint32(3), .uint64(5), .array([.string("text/plain")]), .boolean(true),
        .array([.dictEntry(.string("app"), .variant(.string("firefox")))]),
      ])
    let result = ShellHelperResponses.parseClipboardChanged(signal)
    #expect(result?.selection == 3)
    #expect(result?.clipboardSerial == 5)
    #expect(result?.mimeTypes == ["text/plain"])
    #expect(result?.ownerIsUs == true)
  }

  @Test("parseClipboardChanged rejects a signal from the wrong member")
  func parseClipboardChangedRejectsWrongMember() {
    let signal = DBusMessage(
      type: .signal, serial: 1, interface: ShellHelperName.interface, member: "SomethingElse",
      body: [.uint32(3), .uint64(5), .array([]), .boolean(true), .array([])])
    #expect(ShellHelperResponses.parseClipboardChanged(signal) == nil)
  }

  @Test("ShellHelperClipboardSelection matches Mutter's own MetaSelectionType ordinals")
  func clipboardSelectionMatchesMutterOrdinals() {
    // Verified against Mutter's src/core/meta-selection.h (NONE=0,
    // PRIMARY=1, SECONDARY=2, CLIPBOARD=3, DND=4), not guessed — see
    // ShellHelperClipboardSelection's doc comment.
    #expect(ShellHelperClipboardSelection.primary.rawValue == 1)
    #expect(ShellHelperClipboardSelection.clipboard.rawValue == 3)
  }
}
