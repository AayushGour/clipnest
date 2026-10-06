import Foundation
import Testing

@testable import ClipnestPlatformLinux

private func factoryCall(member: String, body: [DBusValue] = []) -> DBusMessage {
  DBusMessage(
    type: .methodCall, serial: 9, path: "/org/freedesktop/IBus/Factory",
    interface: "org.freedesktop.IBus.Factory", member: member, sender: ":1.1", body: body)
}

private func engineCall(member: String, body: [DBusValue] = []) -> DBusMessage {
  DBusMessage(
    type: .methodCall, serial: 9, path: "/org/freedesktop/IBus/Engine/1",
    interface: "org.freedesktop.IBus.Engine", member: member, sender: ":1.1", body: body)
}

@Suite("IBusInboundRequest.decode — org.freedesktop.IBus.Factory")
struct IBusFactoryDecodeTests {
  @Test("CreateEngine(name) decodes the requested engine name")
  func createEngineDecodesName() {
    let message = factoryCall(member: "CreateEngine", body: [.string("clipnest-snippet-engine")])
    #expect(
      IBusInboundRequest.decode(message) == .createEngine(engineName: "clipnest-snippet-engine"))
  }

  @Test("CreateEngine with no body is .malformed, not a crash")
  func createEngineWithNoBodyIsMalformed() {
    #expect(IBusInboundRequest.decode(factoryCall(member: "CreateEngine")) == .malformed)
  }

  @Test("an unrecognized Factory member decodes to .unknown")
  func unrecognizedFactoryMemberIsUnknown() {
    #expect(IBusInboundRequest.decode(factoryCall(member: "DoesNotExist")) == .unknown)
  }
}

@Suite("IBusInboundRequest.decode — org.freedesktop.IBus.Engine")
struct IBusEngineDecodeTests {
  @Test("FocusIn/FocusOut/Enable/Disable/Reset decode to their own bare case")
  func nullaryMembersDecode() {
    #expect(IBusInboundRequest.decode(engineCall(member: "FocusIn")) == .focusIn)
    #expect(IBusInboundRequest.decode(engineCall(member: "FocusOut")) == .focusOut)
    #expect(IBusInboundRequest.decode(engineCall(member: "Enable")) == .enable)
    #expect(IBusInboundRequest.decode(engineCall(member: "Disable")) == .disable)
    #expect(IBusInboundRequest.decode(engineCall(member: "Reset")) == .reset)
  }

  @Test("SetCapabilities decodes its caps bitmask")
  func setCapabilitiesDecodesBitmask() {
    let bitmask: UInt32 = 1 | 8 | 32  // preedit + focus + surrounding text
    let message = engineCall(member: "SetCapabilities", body: [.uint32(bitmask)])
    #expect(
      IBusInboundRequest.decode(message)
        == .setCapabilities(IBusCapabilities(rawValue: bitmask)))
  }

  @Test("SetCapabilities with a wrong-typed argument is .malformed")
  func setCapabilitiesRejectsWrongType() {
    let message = engineCall(member: "SetCapabilities", body: [.string("32")])
    #expect(IBusInboundRequest.decode(message) == .malformed)
  }

  @Test("ProcessKeyEvent decodes keyval/keycode/state in order")
  func processKeyEventDecodesFields() {
    let message = engineCall(
      member: "ProcessKeyEvent", body: [.uint32(97), .uint32(38), .uint32(0)])
    #expect(
      IBusInboundRequest.decode(message)
        == .processKeyEvent(keyval: 97, keycode: 38, state: 0))
  }

  @Test("ProcessKeyEvent with a missing argument is .malformed")
  func processKeyEventRejectsShortBody() {
    let message = engineCall(member: "ProcessKeyEvent", body: [.uint32(97), .uint32(38)])
    #expect(IBusInboundRequest.decode(message) == .malformed)
  }

  @Test(
    "SetSurroundingText decodes text (from the real IBusText wire shape) plus cursor/anchor as UInt32 character offsets"
  )
  func setSurroundingTextDecodesFields() {
    // Hand-built the same way IBusTextSerializationTests.
    // parseIBusTextDecodesHandBuiltRealShape is -- independently of
    // IBusRequests.serializedText -- so this test doesn't just corroborate
    // this module's own encode/decode pair with itself (T-ATSPI1/D95).
    let handBuiltText = DBusValue.variant(
      .structure([
        .string("IBusText"), .emptyArray(elementSignature: "{sv}"), .string("sig"),
        .variant(
          .structure([
            .string("IBusAttrList"), .emptyArray(elementSignature: "{sv}"),
            .emptyArray(elementSignature: "v"),
          ])),
      ]))
    let message = engineCall(
      member: "SetSurroundingText", body: [handBuiltText, .uint32(3), .uint32(3)])
    #expect(
      IBusInboundRequest.decode(message)
        == .setSurroundingText(text: IBusText(text: "sig"), cursorPos: 3, anchorPos: 3))
  }

  @Test("SetSurroundingText with an unparseable text argument is .malformed, never a crash")
  func setSurroundingTextRejectsUnparseableText() {
    let message = engineCall(
      member: "SetSurroundingText", body: [.string("not a variant"), .uint32(0), .uint32(0)])
    #expect(IBusInboundRequest.decode(message) == .malformed)
  }

  @Test("PropertyActivate decodes name and state")
  func propertyActivateDecodesFields() {
    let message = engineCall(
      member: "PropertyActivate", body: [.string("InputMode.ja"), .uint32(1)])
    #expect(
      IBusInboundRequest.decode(message) == .propertyActivate(name: "InputMode.ja", state: 1))
  }

  @Test(
    "every real org.freedesktop.IBus.Engine member this module doesn't implement decodes to .unknown, never crashes -- SetCursorLocation/ProcessHandWritingEvent/CancelHandWriting/PropertyShow/PropertyHide/CandidateClicked/FocusInId/FocusOutId/PageUp/PageDown/CursorUp/CursorDown/PanelExtensionReceived/PanelExtensionRegisterKeys, verbatim from src/ibusengine.c's own introspection_xml"
  )
  func unimplementedRealEngineMembersDecodeToUnknown() {
    let realButUnimplemented = [
      "SetCursorLocation", "ProcessHandWritingEvent", "CancelHandWriting", "PropertyShow",
      "PropertyHide", "CandidateClicked", "FocusInId", "FocusOutId", "PageUp", "PageDown",
      "CursorUp", "CursorDown", "PanelExtensionReceived", "PanelExtensionRegisterKeys",
    ]
    for member in realButUnimplemented {
      #expect(
        IBusInboundRequest.decode(engineCall(member: member)) == .unknown,
        "expected \(member) to decode to .unknown")
    }
  }

  @Test("a non-method-call message (e.g. a stray signal) decodes to nil")
  func nonMethodCallDecodesToNil() {
    let signal = DBusMessage(
      type: .signal, serial: 1, interface: "org.freedesktop.IBus.Engine", member: "FocusIn")
    #expect(IBusInboundRequest.decode(signal) == nil)
  }

  @Test(
    "an entirely unrelated interface (e.g. a stray Introspectable probe) decodes to .unknown, not a crash"
  )
  func unrelatedInterfaceDecodesToUnknown() {
    let message = DBusMessage(
      type: .methodCall, serial: 1, path: "/org/freedesktop/IBus/Engine/1",
      interface: "org.freedesktop.DBus.Introspectable", member: "Introspect", sender: ":1.1")
    #expect(IBusInboundRequest.decode(message) == .unknown)
  }
}

@Suite("IBusEngineReplies")
struct IBusEngineRepliesTests {
  @Test("empty() replies with a plain METHOD_RETURN addressed back to the sender")
  func emptyReplyAddressesSender() {
    let request = engineCall(member: "FocusIn")
    let reply = IBusEngineReplies.empty(replyingTo: request)
    #expect(reply.type == .methodReturn)
    #expect(reply.replySerial == request.serial)
    #expect(reply.destination == request.sender)
    #expect(reply.body.isEmpty)
  }

  @Test("createEngine() replies with the object path as its only argument")
  func createEngineReplyShape() {
    let request = factoryCall(member: "CreateEngine", body: [.string("x")])
    let reply = IBusEngineReplies.createEngine(
      objectPath: "/org/freedesktop/IBus/Engine/7", replyingTo: request)
    #expect(reply.body == [.objectPath("/org/freedesktop/IBus/Engine/7")])
  }

  @Test("processKeyEventNeverConsumed() replies with exactly [false], unconditionally")
  func processKeyEventNeverConsumedReplyIsAlwaysFalse() {
    let request = engineCall(
      member: "ProcessKeyEvent", body: [.uint32(97), .uint32(38), .uint32(0)])
    let reply = IBusEngineReplies.processKeyEventNeverConsumed(replyingTo: request)
    #expect(reply.type == .methodReturn)
    #expect(reply.body == [.boolean(false)])
  }

  @Test("unknownMethod()/invalidArgs() use the correct D-Bus error names")
  func errorReplyNames() {
    let request = engineCall(member: "DoesNotExist")
    #expect(
      IBusEngineReplies.unknownMethod(replyingTo: request).errorName
        == "org.freedesktop.DBus.Error.UnknownMethod")
    #expect(
      IBusEngineReplies.invalidArgs(replyingTo: request).errorName
        == "org.freedesktop.DBus.Error.InvalidArgs")
  }
}

// MARK: - IBusEngineDispatcher

/// Every closure filled in explicitly (coding-standards.md: "make it
/// explicit at the call site ... never a default the caller can forget")
/// -- `IBusEngineDispatcher`'s own initializer has no defaults at all, so
/// this helper is what keeps each test terse while still wiring every
/// parameter.
private func makeDispatcher(
  onFocusIn: @escaping () -> Void = {},
  onFocusOut: @escaping () -> Void = {},
  onEnable: @escaping () -> Void = {},
  onDisable: @escaping () -> Void = {},
  onReset: @escaping () -> Void = {},
  onSetCapabilities: @escaping (IBusCapabilities) -> Void = { _ in },
  onProcessKeyEvent: @escaping (UInt32, UInt32, UInt32) -> Void = { _, _, _ in },
  onSetSurroundingText: @escaping (IBusText, UInt32, UInt32) -> Void = { _, _, _ in },
  onPropertyActivate: @escaping (String, UInt32) -> Void = { _, _ in },
  onCreateEngine: @escaping (String) -> String = { _ in "" }
) -> IBusEngineDispatcher {
  IBusEngineDispatcher(
    onFocusIn: onFocusIn, onFocusOut: onFocusOut, onEnable: onEnable, onDisable: onDisable,
    onReset: onReset, onSetCapabilities: onSetCapabilities, onProcessKeyEvent: onProcessKeyEvent,
    onSetSurroundingText: onSetSurroundingText, onPropertyActivate: onPropertyActivate,
    onCreateEngine: onCreateEngine)
}

@Suite("IBusEngineDispatcher — pure dispatch, no DBusConnection needed")
struct IBusEngineDispatcherTests {
  // MARK: Correctness requirement #1 (T-IBUS-WIRE)

  @Test(
    "ProcessKeyEvent's reply is unconditionally [false] even though onProcessKeyEvent fired -- the closure cannot influence the reply, by construction (Void return)"
  )
  func processKeyEventNeverConsumedRegardlessOfHandler() {
    var observed: (keyval: UInt32, keycode: UInt32, state: UInt32)?
    let dispatcher = makeDispatcher(onProcessKeyEvent: { keyval, keycode, state in
      observed = (keyval, keycode, state)
    })
    let message = engineCall(
      member: "ProcessKeyEvent", body: [.uint32(118), .uint32(55), .uint32(0)])
    let reply = dispatcher.handle(
      .processKeyEvent(keyval: 118, keycode: 55, state: 0), message: message)
    #expect(observed?.keyval == 118)
    #expect(reply?.body == [.boolean(false)])
  }

  @Test(
    "ProcessKeyEvent reports not-consumed across every modifier state, including Super+Shift held -- the exact merge this feature exists to be immune to"
  )
  func processKeyEventNeverConsumedAcrossModifierStates() {
    let dispatcher = makeDispatcher()
    // state values are opaque X11/IBus modifier bitmasks to this
    // dispatcher -- it must not special-case any of them.
    for state: UInt32 in [0, 1, 4, 64, 68, 0xFFFF_FFFF] {
      let message = engineCall(
        member: "ProcessKeyEvent", body: [.uint32(99), .uint32(54), .uint32(state)])
      let reply = dispatcher.handle(
        .processKeyEvent(keyval: 99, keycode: 54, state: state), message: message)
      #expect(reply?.body == [.boolean(false)], "state=\(state) must still report not-consumed")
    }
  }

  // MARK: Correctness requirement #2 (T-IBUS-WIRE) -- safe reply, never a crash

  @Test(
    ".unknown replies with UnknownMethod; .malformed replies with InvalidArgs -- both safe, no crash"
  )
  func unknownAndMalformedProduceSafeErrorReplies() {
    let dispatcher = makeDispatcher()
    let message = engineCall(member: "DoesNotExist")
    #expect(dispatcher.handle(.unknown, message: message)?.type == .error)
    #expect(dispatcher.handle(.malformed, message: message)?.type == .error)
    #expect(
      dispatcher.handle(.unknown, message: message)?.errorName
        == "org.freedesktop.DBus.Error.UnknownMethod")
    #expect(
      dispatcher.handle(.malformed, message: message)?.errorName
        == "org.freedesktop.DBus.Error.InvalidArgs")
  }

  // MARK: Wiring -- each request invokes exactly its own handler

  @Test("FocusIn/FocusOut/Enable/Disable/Reset each invoke exactly their own closure")
  func nullaryRequestsInvokeTheirOwnHandler() {
    var focusInCount = 0
    var focusOutCount = 0
    var enableCount = 0
    var disableCount = 0
    var resetCount = 0
    let dispatcher = makeDispatcher(
      onFocusIn: { focusInCount += 1 }, onFocusOut: { focusOutCount += 1 },
      onEnable: { enableCount += 1 }, onDisable: { disableCount += 1 },
      onReset: { resetCount += 1 })

    let message = engineCall(member: "FocusIn")
    _ = dispatcher.handle(.focusIn, message: message)
    _ = dispatcher.handle(.focusOut, message: message)
    _ = dispatcher.handle(.enable, message: message)
    _ = dispatcher.handle(.disable, message: message)
    _ = dispatcher.handle(.reset, message: message)

    #expect(focusInCount == 1)
    #expect(focusOutCount == 1)
    #expect(enableCount == 1)
    #expect(disableCount == 1)
    #expect(resetCount == 1)
  }

  @Test("SetCapabilities invokes onSetCapabilities with the decoded bitmask")
  func setCapabilitiesInvokesHandler() {
    var observed: IBusCapabilities?
    let dispatcher = makeDispatcher(onSetCapabilities: { observed = $0 })
    let message = engineCall(member: "SetCapabilities", body: [.uint32(32)])
    _ = dispatcher.handle(.setCapabilities(.surroundingText), message: message)
    #expect(observed == .surroundingText)
  }

  @Test("SetSurroundingText invokes onSetSurroundingText with text/cursorPos/anchorPos")
  func setSurroundingTextInvokesHandler() {
    var observed: (text: IBusText, cursorPos: UInt32, anchorPos: UInt32)?
    let dispatcher = makeDispatcher(onSetSurroundingText: { text, cursorPos, anchorPos in
      observed = (text, cursorPos, anchorPos)
    })
    let message = engineCall(member: "SetSurroundingText")
    _ = dispatcher.handle(
      .setSurroundingText(text: IBusText(text: "sig"), cursorPos: 3, anchorPos: 3),
      message: message)
    #expect(observed?.text == IBusText(text: "sig"))
    #expect(observed?.cursorPos == 3)
  }

  @Test("PropertyActivate invokes onPropertyActivate with name/state")
  func propertyActivateInvokesHandler() {
    var observed: (name: String, state: UInt32)?
    let dispatcher = makeDispatcher(onPropertyActivate: { observed = ($0, $1) })
    let message = engineCall(member: "PropertyActivate")
    _ = dispatcher.handle(.propertyActivate(name: "InputMode.ja", state: 1), message: message)
    #expect(observed?.name == "InputMode.ja")
  }

  @Test("CreateEngine calls onCreateEngine and replies with the object path it returns")
  func createEngineInvokesHandlerAndRepliesWithItsPath() {
    var requestedName: String?
    let dispatcher = makeDispatcher(onCreateEngine: { name in
      requestedName = name
      return "/org/freedesktop/IBus/Engine/42"
    })
    let message = factoryCall(member: "CreateEngine", body: [.string("clipnest-snippet-engine")])
    let reply = dispatcher.handle(
      .createEngine(engineName: "clipnest-snippet-engine"), message: message)
    #expect(requestedName == "clipnest-snippet-engine")
    #expect(reply?.body == [.objectPath("/org/freedesktop/IBus/Engine/42")])
  }
}
