import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("IBusRequests — org.freedesktop.IBus (bus) calls")
struct IBusRequestsBusTests {
  @Test("registerComponent() targets the daemon with a variant-wrapped IBusComponent body")
  func registerComponentMessageShape() {
    let component = IBusComponentDescriptor(
      name: "app.clipnest.snippetengine", description: "Clipnest snippet engine",
      version: "1.0", license: "MIT", author: "Clipnest", homepage: "", exec: "",
      textDomain: "", engines: [])
    let message = IBusRequests.registerComponent(component, serial: 1)
    #expect(message.destination == "org.freedesktop.IBus")
    #expect(message.path == "/org/freedesktop/IBus")
    #expect(message.interface == "org.freedesktop.IBus")
    #expect(message.member == "RegisterComponent")
    guard case .variant(.structure(let fields))? = message.body.first else {
      Issue.record("expected a variant<structure> body")
      return
    }
    #expect(fields.first == .string("IBusComponent"))
  }

  @Test("setGlobalEngine() carries the engine name as its only argument")
  func setGlobalEngineMessageShape() {
    let message = IBusRequests.setGlobalEngine(name: "clipnest-snippet-engine", serial: 2)
    #expect(message.member == "SetGlobalEngine")
    #expect(message.body == [.string("clipnest-snippet-engine")])
  }

  @Test("getGlobalEngine() has no arguments")
  func getGlobalEngineMessageShape() {
    let message = IBusRequests.getGlobalEngine(serial: 3)
    #expect(message.member == "GetGlobalEngine")
    #expect(message.body.isEmpty)
  }

  @Test("currentInputContext() has no arguments")
  func currentInputContextMessageShape() {
    let message = IBusRequests.currentInputContext(serial: 4)
    #expect(message.member == "CurrentInputContext")
    #expect(message.body.isEmpty)
  }
}

@Suite("IBusRequests — org.freedesktop.IBus.Engine signals this app emits")
struct IBusRequestsEngineSignalTests {
  @Test("commitText() is a SIGNAL (not a method call) carrying a variant-wrapped IBusText")
  func commitTextMessageShape() {
    let message = IBusRequests.commitText(
      IBusText(text: "Best regards, Clipnest"), objectPath: "/org/freedesktop/IBus/Engine/1",
      serial: 5)
    #expect(message.type == .signal)
    #expect(message.path == "/org/freedesktop/IBus/Engine/1")
    #expect(message.interface == "org.freedesktop.IBus.Engine")
    #expect(message.member == "CommitText")
    #expect(message.destination == nil)
    guard case .variant(.structure(let fields))? = message.body.first, fields.count == 4 else {
      Issue.record("expected a 4-field variant<structure> IBusText body")
      return
    }
    #expect(fields[0] == .string("IBusText"))
    #expect(fields[2] == .string("Best regards, Clipnest"))
  }

  @Test(
    "deleteSurroundingText() wire order is (offset: i, nchars: u) — matches ibus_engine_delete_surrounding_text's own g_variant_new(\"(iu)\", offset_from_cursor, nchars) verbatim"
  )
  func deleteSurroundingTextMessageShape() {
    let message = IBusRequests.deleteSurroundingText(
      offsetFromCursor: -9, characterCount: 9, objectPath: "/org/freedesktop/IBus/Engine/1",
      serial: 6)
    #expect(message.type == .signal)
    #expect(message.member == "DeleteSurroundingText")
    #expect(message.body == [.int32(-9), .uint32(9)])
  }

  @Test(
    "requireSurroundingText() is a nullary signal (no body) — matches ibus_engine_emit_signal(engine, \"RequireSurroundingText\", NULL) verbatim"
  )
  func requireSurroundingTextMessageShape() {
    let message = IBusRequests.requireSurroundingText(
      objectPath: "/org/freedesktop/IBus/Engine/1", serial: 7)
    #expect(message.type == .signal)
    #expect(message.member == "RequireSurroundingText")
    #expect(message.body.isEmpty)
  }
}

@Suite("IBusText wire serialization — IBusRequests.serializedText / IBusResponses.parseIBusText")
struct IBusTextSerializationTests {
  @Test("serializedText produces the exact (s a{sv} s v) tuple ibus_text_serialize builds")
  func serializedTextTupleShape() {
    let serialized = IBusRequests.serializedText(IBusText(text: "sig"))
    guard case .structure(let fields) = serialized, fields.count == 4 else {
      Issue.record("expected a 4-field structure")
      return
    }
    #expect(fields[0] == .string("IBusText"))
    #expect(fields[1] == .emptyArray(elementSignature: "{sv}"))
    #expect(fields[2] == .string("sig"))
    guard case .variant(.structure(let attrListFields)) = fields[3], attrListFields.count == 3
    else {
      Issue.record("expected the attrs field to be a variant-wrapped IBusAttrList structure")
      return
    }
    #expect(attrListFields[0] == .string("IBusAttrList"))
    #expect(attrListFields[1] == .emptyArray(elementSignature: "{sv}"))
    #expect(attrListFields[2] == .emptyArray(elementSignature: "v"))
  }

  @Test(
    "parseIBusText decodes text from the REAL wire shape, hand-built independently of serializedText (not round-tripped through it) — the D95/T-ATSPI1 antidote: production encode and this test's fixture must NOT share one author's single guess"
  )
  func parseIBusTextDecodesHandBuiltRealShape() {
    // Hand-built exactly as `ibus_serializable_serialize_object` +
    // `ibus_text_serialize` + `ibus_attr_list_serialize` chain them
    // (curl'd directly from src/ibusserializable.c, src/ibustext.c,
    // src/ibusattrlist.c — see IBusRequests.serializedText's doc comment
    // for the full citation), NOT produced by calling
    // IBusRequests.serializedText itself.
    let handBuiltAttrList = DBusValue.structure([
      .string("IBusAttrList"), .emptyArray(elementSignature: "{sv}"),
      .emptyArray(elementSignature: "v"),
    ])
    let handBuiltText = DBusValue.variant(
      .structure([
        .string("IBusText"), .emptyArray(elementSignature: "{sv}"), .string("sig"),
        .variant(handBuiltAttrList),
      ]))
    #expect(IBusResponses.parseIBusText(handBuiltText) == IBusText(text: "sig"))
  }

  @Test("round trip: serializedText -> wrap in variant -> parseIBusText recovers the original text")
  func serializeParseRoundTrip() {
    let original = IBusText(text: "hello, 世界")
    let wireValue = DBusValue.variant(IBusRequests.serializedText(original))
    #expect(IBusResponses.parseIBusText(wireValue) == original)
  }

  @Test(
    "parseIBusText rejects a differently-typed serializable, never silently misreads it as text")
  func parseIBusTextRejectsWrongTypeName() {
    let notText = DBusValue.variant(
      .structure([
        .string("IBusAttrList"), .emptyArray(elementSignature: "{sv}"),
        .emptyArray(elementSignature: "v"),
      ]))
    #expect(IBusResponses.parseIBusText(notText) == nil)
  }

  @Test("parseIBusText rejects a bare (non-variant) value and a too-short tuple")
  func parseIBusTextRejectsMalformedShapes() {
    #expect(IBusResponses.parseIBusText(.string("not even a variant")) == nil)
    #expect(IBusResponses.parseIBusText(.variant(.structure([.string("IBusText")]))) == nil)
  }
}

@Suite("IBusComponentDescriptor / IBusEngineDescriptor serialization")
struct IBusComponentDescriptorSerializationTests {
  @Test(
    "IBusEngineDescriptor.serialized() emits all 17 own fields in ibus_engine_desc_serialize's exact order, after the 2 base fields"
  )
  func engineDescriptorFieldOrder() {
    let descriptor = IBusEngineDescriptor(
      name: "clipnest-snippet-engine", longName: "Clipnest Snippet Engine",
      description: "Keystroke-free snippet expansion", language: "en", license: "MIT",
      author: "Clipnest", icon: "", layout: "us", rank: 0)
    guard case .structure(let fields) = descriptor.serialized() else {
      Issue.record("expected a structure")
      return
    }
    #expect(fields.count == 19)  // 2 base + 8 strings + 1 rank + 8 trailing strings
    #expect(fields[0] == .string("IBusEngineDesc"))
    #expect(fields[1] == .emptyArray(elementSignature: "{sv}"))
    #expect(fields[2] == .string("clipnest-snippet-engine"))
    #expect(fields[3] == .string("Clipnest Snippet Engine"))
    #expect(fields[9] == .string("us"))
    #expect(fields[10] == .uint32(0))
    // The 8 trailing fields this app never sets are still emitted, always "".
    #expect(fields[11...18].allSatisfy { $0 == .string("") })
  }

  @Test("IBusComponentDescriptor.serialized() carries its engines as a variant-wrapped av")
  func componentDescriptorEnginesField() {
    let engine = IBusEngineDescriptor(
      name: "clipnest-snippet-engine", longName: "Clipnest Snippet Engine",
      description: "", language: "en")
    let component = IBusComponentDescriptor(
      name: "app.clipnest.snippetengine", description: "", version: "1.0", license: "MIT",
      author: "Clipnest", homepage: "", exec: "", textDomain: "", engines: [engine])
    guard case .structure(let fields) = component.serialized(), fields.count == 12 else {
      Issue.record("expected a 12-field structure (2 base + 8 strings + 2 av)")
      return
    }
    #expect(fields[0] == .string("IBusComponent"))
    #expect(fields[10] == .emptyArray(elementSignature: "v"))  // observed_paths, always empty
    guard case .array(let engineVariants) = fields[11], engineVariants.count == 1 else {
      Issue.record("expected exactly one variant-wrapped engine descriptor")
      return
    }
    #expect(engineVariants[0] == .variant(engine.serialized()))
  }

  @Test("an empty engines list serializes to an empty av, not a bare byte array")
  func emptyEnginesListUsesCorrectElementSignature() {
    let component = IBusComponentDescriptor(
      name: "x", description: "", version: "", license: "", author: "", homepage: "", exec: "",
      textDomain: "", engines: [])
    guard case .structure(let fields) = component.serialized() else {
      Issue.record("expected a structure")
      return
    }
    #expect(fields.last == .emptyArray(elementSignature: "v"))
  }
}

@Suite("IBusResponses — bus call replies")
struct IBusResponsesTests {
  @Test("isSuccessReply is true for a METHOD_RETURN and false for an ERROR")
  func isSuccessReplyDistinguishesReturnFromError() {
    #expect(IBusResponses.isSuccessReply(fakeMethodReturn()))
    let error = DBusMessage(
      type: .error, serial: 1, errorName: "org.freedesktop.DBus.Error.Failed", replySerial: 1)
    #expect(!IBusResponses.isSuccessReply(error))
  }

  @Test(
    "parseGetGlobalEngineReply extracts the engine's name (field index 2) from the wrapped IBusEngineDesc"
  )
  func parseGetGlobalEngineReplyExtractsName() {
    let descriptor = IBusEngineDescriptor(
      name: "clipnest-snippet-engine", longName: "", description: "", language: "en")
    let reply = fakeMethodReturn(body: [.variant(descriptor.serialized())])
    #expect(IBusResponses.parseGetGlobalEngineReply(reply) == "clipnest-snippet-engine")
  }

  @Test("parseGetGlobalEngineReply returns nil for a malformed reply")
  func parseGetGlobalEngineReplyRejectsMalformed() {
    #expect(IBusResponses.parseGetGlobalEngineReply(fakeMethodReturn(body: [.string("x")])) == nil)
  }

  @Test("parseCurrentInputContextReply extracts the object path")
  func parseCurrentInputContextReplyExtractsPath() {
    let reply = fakeMethodReturn(body: [.objectPath("/org/freedesktop/IBus/InputContext_1")])
    #expect(
      IBusResponses.parseCurrentInputContextReply(reply)
        == "/org/freedesktop/IBus/InputContext_1")
  }

  @Test("parseCurrentInputContextReply rejects a plain string masquerading as an object path")
  func parseCurrentInputContextReplyRejectsPlainString() {
    let reply = fakeMethodReturn(body: [.string("/org/freedesktop/IBus/InputContext_1")])
    #expect(IBusResponses.parseCurrentInputContextReply(reply) == nil)
  }
}

@Suite("IBusCapabilities — SetCapabilities' caps bitmask, verbatim from src/ibustypes.h")
struct IBusCapabilitiesTests {
  @Test("every named bit matches ibus's own IBusCapabilite enum values exactly")
  func bitValuesMatchUpstream() {
    #expect(IBusCapabilities.preeditText.rawValue == 1)
    #expect(IBusCapabilities.auxiliaryText.rawValue == 2)
    #expect(IBusCapabilities.lookupTable.rawValue == 4)
    #expect(IBusCapabilities.focus.rawValue == 8)
    #expect(IBusCapabilities.property.rawValue == 16)
    #expect(IBusCapabilities.surroundingText.rawValue == 32)
    #expect(IBusCapabilities.osk.rawValue == 64)
    #expect(IBusCapabilities.syncProcessKey.rawValue == 128)
  }

  @Test("a real SetCapabilities bitmask decodes with .contains, not equality")
  func containsChecksTheRightBit() {
    let bitmask: UInt32 = 1 | 8 | 32  // preedit + focus + surrounding text
    let caps = IBusCapabilities(rawValue: bitmask)
    #expect(caps.contains(.surroundingText))
    #expect(caps.contains(.focus))
    #expect(!caps.contains(.lookupTable))
  }
}
