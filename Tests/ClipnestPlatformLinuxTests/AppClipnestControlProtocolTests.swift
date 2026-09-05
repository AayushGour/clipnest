import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

private func call(
  interface: String, member: String, body: [DBusValue] = []
) -> DBusMessage {
  DBusMessage(
    type: .methodCall, serial: 7, path: "/app/clipnest/Clipnest", interface: interface,
    member: member, sender: ":1.99", body: body)
}

@Suite("ClipnestControlRequest.decode — app.clipnest.Control")
struct AppClipnestControlProtocolTests {
  @Test("TogglePicker/HidePicker/ExpandSnippet/OpenSettings/Ping decode to their own case")
  func simpleMembersDecode() {
    #expect(
      ClipnestControlRequest.decode(call(interface: "app.clipnest.Control", member: "TogglePicker"))
        == .togglePicker)
    #expect(
      ClipnestControlRequest.decode(call(interface: "app.clipnest.Control", member: "HidePicker"))
        == .hidePicker)
    #expect(
      ClipnestControlRequest.decode(
        call(interface: "app.clipnest.Control", member: "ExpandSnippet")) == .expandSnippet)
    #expect(
      ClipnestControlRequest.decode(
        call(interface: "app.clipnest.Control", member: "OpenSettings")) == .openSettings)
    #expect(
      ClipnestControlRequest.decode(call(interface: "app.clipnest.Control", member: "Ping"))
        == .ping)
  }

  @Test("ShowPicker with an a{sv} options body decodes with pointer/monitor parsed")
  func showPickerDecodesOptions() {
    let options: DBusValue = .array([
      .dictEntry(.string("pointer-x"), .variant(.int32(10))),
      .dictEntry(.string("pointer-y"), .variant(.int32(20))),
      .dictEntry(.string("monitor"), .variant(.int32(1))),
    ])
    let message = call(interface: "app.clipnest.Control", member: "ShowPicker", body: [options])
    guard case .showPicker(let decoded)? = ClipnestControlRequest.decode(message) else {
      Issue.record("expected .showPicker")
      return
    }
    #expect(decoded.pointer?.x == 10)
    #expect(decoded.pointer?.y == 20)
    #expect(decoded.monitor == 1)
  }

  @Test("ShowPicker with no body at all decodes to empty options, never a crash")
  func showPickerWithNoBodyDecodesEmpty() {
    let message = call(interface: "app.clipnest.Control", member: "ShowPicker")
    #expect(ClipnestControlRequest.decode(message) == .showPicker(.empty))
  }

  @Test("an unrecognized member on app.clipnest.Control decodes to .unknown")
  func unrecognizedControlMemberIsUnknown() {
    #expect(
      ClipnestControlRequest.decode(call(interface: "app.clipnest.Control", member: "DoesNotExist"))
        == .unknown)
  }

  @Test("a non-method-call message (e.g. a stray signal) decodes to nil")
  func nonMethodCallDecodesToNil() {
    let signal = DBusMessage(
      type: .signal, serial: 1, interface: "app.clipnest.Control", member: "TogglePicker")
    #expect(ClipnestControlRequest.decode(signal) == nil)
  }
}

@Suite("ClipnestControlRequest.decode — org.freedesktop.Application")
struct AppFreedesktopApplicationProtocolTests {
  @Test("Activate decodes to .activate")
  func activateDecodes() {
    #expect(
      ClipnestControlRequest.decode(
        call(interface: "org.freedesktop.Application", member: "Activate")) == .activate)
  }

  @Test("Open decodes its uris array, tolerating a missing/malformed body as empty")
  func openDecodesUris() {
    let withURIs = call(
      interface: "org.freedesktop.Application", member: "Open",
      body: [.array([.string("--toggle-picker")]), .array([])])
    #expect(ClipnestControlRequest.decode(withURIs) == .open(["--toggle-picker"]))

    let withoutBody = call(interface: "org.freedesktop.Application", member: "Open")
    #expect(ClipnestControlRequest.decode(withoutBody) == .open([]))
  }

  @Test("ActivateAction decodes its name, or .malformed if the argument is missing")
  func activateActionDecodesName() {
    let withName = call(
      interface: "org.freedesktop.Application", member: "ActivateAction",
      body: [.string("opensettings")])
    #expect(ClipnestControlRequest.decode(withName) == .activateAction(name: "opensettings"))

    let withoutName = call(interface: "org.freedesktop.Application", member: "ActivateAction")
    #expect(ClipnestControlRequest.decode(withoutName) == .malformed)
  }
}

@Suite("ClipnestControlRequest.decode — org.freedesktop.DBus.Properties")
struct AppFreedesktopPropertiesProtocolTests {
  @Test("Get(app.clipnest.Control, Capabilities) decodes to .getCapabilities")
  func getCapabilitiesDecodes() {
    let message = call(
      interface: "org.freedesktop.DBus.Properties", member: "Get",
      body: [.string("app.clipnest.Control"), .string("Capabilities")])
    #expect(ClipnestControlRequest.decode(message) == .getCapabilities)
  }

  @Test("Get on any other property/interface is .malformed, not silently ignored")
  func getOnUnknownPropertyIsMalformed() {
    let message = call(
      interface: "org.freedesktop.DBus.Properties", member: "Get",
      body: [.string("app.clipnest.Control"), .string("SomethingElse")])
    #expect(ClipnestControlRequest.decode(message) == .malformed)
  }

  @Test("GetAll(app.clipnest.Control) decodes to .getAllProperties")
  func getAllDecodes() {
    let message = call(
      interface: "org.freedesktop.DBus.Properties", member: "GetAll",
      body: [.string("app.clipnest.Control")])
    #expect(ClipnestControlRequest.decode(message) == .getAllProperties)
  }
}

@Suite("ClipnestControlReplies")
struct AppClipnestControlRepliesTests {
  @Test("empty() replies with a plain METHOD_RETURN addressed back to the sender")
  func emptyReplyAddressesSender() {
    let request = call(interface: "app.clipnest.Control", member: "TogglePicker")
    let reply = ClipnestControlReplies.empty(replyingTo: request)
    #expect(reply.type == .methodReturn)
    #expect(reply.replySerial == request.serial)
    #expect(reply.destination == request.sender)
    #expect(reply.body.isEmpty)
  }

  @Test("capabilities() wraps the list in a single variant<array<string>>")
  func capabilitiesReplyShape() {
    let request = call(interface: "org.freedesktop.DBus.Properties", member: "Get")
    let reply = ClipnestControlReplies.capabilities(["picker", "settings"], replyingTo: request)
    guard case .variant(.array(let items))? = reply.body.first else {
      Issue.record("expected variant<array<string>>")
      return
    }
    #expect(items == [.string("picker"), .string("settings")])
  }

  @Test("allProperties() wraps Capabilities under a single dict entry")
  func allPropertiesReplyShape() {
    let request = call(interface: "org.freedesktop.DBus.Properties", member: "GetAll")
    let reply = ClipnestControlReplies.allProperties(["picker"], replyingTo: request)
    guard case .array(let entries)? = reply.body.first, entries.count == 1,
      case .dictEntry(.string(let key), .variant(.array(let values))) = entries[0]
    else {
      Issue.record("expected a{sv} with exactly one Capabilities entry")
      return
    }
    #expect(key == "Capabilities")
    #expect(values == [.string("picker")])
  }

  @Test("unknownMethod() replies with the correct D-Bus error name")
  func unknownMethodErrorName() {
    let request = call(interface: "app.clipnest.Control", member: "DoesNotExist")
    let reply = ClipnestControlReplies.unknownMethod(replyingTo: request)
    #expect(reply.type == .error)
    #expect(reply.errorName == "org.freedesktop.DBus.Error.UnknownMethod")
  }
}

@Suite("ClipnestControlReceiveRejection — T-LX2 receive-loop rejection logging")
struct AppClipnestControlReceiveRejectionTests {
  @Test("notAMethodCall names the message's type, interface, and member")
  func notAMethodCallDescribesMetadataOnly() {
    let signal = DBusMessage(
      type: .signal, serial: 3, interface: "org.freedesktop.DBus", member: "NameOwnerChanged")
    let description = ClipnestControlReceiveRejection.notAMethodCall(signal).logDescription
    #expect(description.contains("signal"))
    #expect(description.contains("org.freedesktop.DBus"))
    #expect(description.contains("NameOwnerChanged"))
  }

  @Test("notAMethodCall tolerates a message with no interface/member, never crashing")
  func notAMethodCallToleratesMissingMetadata() {
    let bareReply = DBusMessage(type: .methodReturn, serial: 4, replySerial: 1)
    let description = ClipnestControlReceiveRejection.notAMethodCall(bareReply).logDescription
    #expect(description.contains("?"))
  }

  @Test("noReplyProduced names the request's interface and member")
  func noReplyProducedDescribesMetadataOnly() {
    let message = call(interface: "app.clipnest.Control", member: "Ping")
    let description = ClipnestControlReceiveRejection.noReplyProduced(message).logDescription
    #expect(description.contains("app.clipnest.Control"))
    #expect(description.contains("Ping"))
  }
}

@Suite("ClipnestControlDispatcher — pure dispatch, no DBusConnection needed")
struct AppClipnestControlServiceDispatchTests {
  @Test("TogglePicker and Activate both invoke onTogglePicker")
  func togglePickerAndActivateShareAHandler() {
    let dispatcher = ClipnestControlDispatcher(capabilities: [])
    var toggled = 0
    dispatcher.onTogglePicker = { toggled += 1 }

    let message = call(interface: "app.clipnest.Control", member: "TogglePicker")
    _ = dispatcher.handle(.togglePicker, message: message)
    _ = dispatcher.handle(.activate, message: message)
    #expect(toggled == 2)
  }

  @Test("Open([--expand-snippet]) routes to onExpandSnippet, not onTogglePicker")
  func openWithExpandSnippetFlagRoutesCorrectly() {
    let dispatcher = ClipnestControlDispatcher(capabilities: [])
    var toggled = 0
    var expanded = 0
    dispatcher.onTogglePicker = { toggled += 1 }
    dispatcher.onExpandSnippet = { expanded += 1 }

    let message = call(interface: "org.freedesktop.Application", member: "Open")
    _ = dispatcher.handle(.open(["--expand-snippet"]), message: message)
    #expect(expanded == 1)
    #expect(toggled == 0)
  }

  @Test("getCapabilities replies with exactly the injected capabilities list")
  func getCapabilitiesRepliesWithInjectedList() {
    let dispatcher = ClipnestControlDispatcher(capabilities: ["picker", "settings"])
    let message = call(interface: "org.freedesktop.DBus.Properties", member: "Get")
    let reply = dispatcher.handle(.getCapabilities, message: message)
    guard case .variant(.array(let items))? = reply?.body.first else {
      Issue.record("expected variant<array<string>>")
      return
    }
    #expect(items == [.string("picker"), .string("settings")])
  }

  @Test("an unknown request replies with UnknownMethod")
  func unknownRequestRepliesWithError() {
    let dispatcher = ClipnestControlDispatcher(capabilities: [])
    let message = call(interface: "app.clipnest.Control", member: "DoesNotExist")
    let reply = dispatcher.handle(.unknown, message: message)
    #expect(reply?.type == .error)
  }
}
