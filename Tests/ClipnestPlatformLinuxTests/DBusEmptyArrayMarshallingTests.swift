import Foundation
import Testing

@testable import ClipnestLinuxAppKit
@testable import ClipnestPlatformLinux

/// Pure marshalling coverage for `DBusValue.emptyArray(elementSignature:)` —
/// the fix for a real, confirmed connection-fatal bug: `DBusValue.array(
/// [])`'s `signatureCode` degraded EVERY genuinely empty array to `"ay"`
/// (byte array), because nothing about an empty `[DBusValue]` can tell it
/// what element type was intended. `com.canonical.dbusmenu`'s `GetLayout`
/// reply always contains at least one empty array that is NOT bytes
/// (`properties: a{sv}`, every leaf's `children: av`), and a real client
/// validating the reply's declared signature against its own expected
/// type disconnected mid-reply the moment it saw `"ay"` where `"av"`/
/// `"a{sv}"` was meant (`dbus-send` and gnome-panel's own
/// `LIBDBUSMENU-GLIB-WARNING: Getting layout failed: Operation was
/// cancelled`, both confirmed against a real bus — see
/// `debian/README.source`'s "Known gap #4").
///
/// Same "pure logic, byte-level round trip" style as
/// `DBusMarshallingRoundTripTests`/`DBusUnixFDMarshallingTests` — none of
/// this needs a real socket or bus.
@Suite("DBusValue.emptyArray marshalling")
struct DBusEmptyArrayMarshallingTests {
  @Test("signatureCode uses the DECLARED element signature, never \"y\" by default")
  func signatureCodeUsesDeclaredElementType() {
    #expect(DBusValue.emptyArray(elementSignature: "v").signatureCode == "av")
    #expect(DBusValue.emptyArray(elementSignature: "{sv}").signatureCode == "a{sv}")
    #expect(DBusValue.emptyArray(elementSignature: "(ia{sv})").signatureCode == "a(ia{sv})")
    // A genuinely empty `.array([])` is UNCHANGED — still means "empty
    // array of bytes", the one case where inferring "y" is correct.
    #expect(DBusValue.array([]).signatureCode == "ay")
  }

  @Test(
    "an .emptyArray's OWN alignment is always 4, exactly like .array — ARRAY aligns to 4 regardless of contents"
  )
  func emptyArrayOwnAlignmentIsFour() {
    #expect(DBusValue.emptyArray(elementSignature: "v").alignment == 4)
    #expect(DBusValue.emptyArray(elementSignature: "{sv}").alignment == 4)
  }

  @Test(
    "DBusTypeSignature.alignment(ofElementSignature:) mirrors the real per-type alignment table")
  func elementSignatureAlignmentMatchesRealTypes() {
    #expect(DBusTypeSignature.alignment(ofElementSignature: "y") == 1)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "v") == 1)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "n") == 2)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "i") == 4)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "{sv}") == 8)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "(ia{sv})") == 8)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "x") == 8)
  }

  @Test("a malformed element signature falls back to the safe default (4) instead of crashing")
  func malformedElementSignatureFallsBackSafely() {
    #expect(DBusTypeSignature.alignment(ofElementSignature: "Z") == 4)
    #expect(DBusTypeSignature.alignment(ofElementSignature: "") == 4)
  }

  @Test(
    "wire bytes: empty av and empty ay are BYTE-IDENTICAL (both alignment 1) — only the signature string distinguishes them, which is exactly what a strict client like libdbusmenu-glib validates"
  )
  func emptyAvAndEmptyAyProduceIdenticalPaddingButDifferentSignatures() {
    var ayWriter = DBusByteWriter()
    ayWriter.write(.array([]))
    var avWriter = DBusByteWriter()
    avWriter.write(.emptyArray(elementSignature: "v"))

    #expect(ayWriter.bytes == [0, 0, 0, 0], "UINT32 length of 0, no trailing padding needed")
    #expect(avWriter.bytes == [0, 0, 0, 0], "identical raw bytes to the ay case")
    #expect(ayWriter.bytes == avWriter.bytes)
    #expect(
      DBusValue.array([]).signatureCode != DBusValue.emptyArray(elementSignature: "v").signatureCode
    )
  }

  @Test(
    "wire bytes: empty a{sv} needs 4 extra padding bytes an empty ay/av does not — DICT_ENTRY aligns to 8, not 1"
  )
  func emptyDictEntryArrayNeedsExtraPadding() {
    var writer = DBusByteWriter()
    writer.write(.emptyArray(elementSignature: "{sv}"))
    // 4 bytes for the UINT32(0) length, then 4 bytes of padding to reach
    // the DICT_ENTRY element type's 8-byte alignment boundary — this is
    // exactly the padding a blanket "always align to 4" fallback would
    // have gotten wrong (and did, for every empty array, before this case
    // existed), silently shifting whatever field comes after it.
    #expect(writer.bytes == [0, 0, 0, 0, 0, 0, 0, 0])
    #expect(writer.bytes.count == 8)
  }

  @Test("array(_:elementSignature:) picks .array when non-empty, .emptyArray when empty")
  func factoryPicksTheCorrectCase() {
    #expect(DBusValue.array([.string("a")], elementSignature: "s") == .array([.string("a")]))
    #expect(
      DBusValue.array([], elementSignature: "v") == .emptyArray(elementSignature: "v"))
    #expect(DBusValue.array([], elementSignature: "v").signatureCode == "av")
  }

  @Test("DBusElementSignature's shared fragments are each exactly one valid array element type")
  func sharedElementSignatureFragmentsAreValid() {
    #expect(
      DBusSignatureParser.parse("a" + DBusElementSignature.stringVariantDictEntry)
        == [.array(.dictEntry(.string, .variant))])
    #expect(DBusSignatureParser.parse("a" + DBusElementSignature.variant) == [.array(.variant)])
    // (INT32, a{sv}) — the `a{sv}` field parses to `.array(.dictEntry(...))`,
    // not a bare `.dictEntry(...)`.
    #expect(
      DBusSignatureParser.parse("a" + DBusElementSignature.menuGroupPropertiesEntry)
        == [.array(.structure([.int32, .array(.dictEntry(.string, .variant))]))])
  }

  @Test(
    "a full DBusMessage's SIGNATURE header field carries av/a{sv}, decode reads it back unmodified"
  )
  func messageSignatureHeaderCarriesTheDeclaredType() {
    let message = DBusMessage(
      type: .methodReturn, serial: 1, replySerial: 1,
      body: [.emptyArray(elementSignature: "v"), .emptyArray(elementSignature: "{sv}")])
    #expect(message.signature == "ava{sv}")

    let encoded = message.encoded()
    guard let (decoded, consumed) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode a message with .emptyArray body values")
      return
    }
    #expect(consumed == encoded.count)
    #expect(decoded.signature == "ava{sv}")
    // Decoding never re-synthesizes `.emptyArray` (it doesn't need to —
    // the element type is already known from the signature it decodes
    // against), so the round-tripped body is the plain, equally-correct
    // `.array([])` for both — this is expected, not a regression: see
    // `DBusValue.emptyArray`'s own doc comment on why only ENCODING needs
    // this case.
    #expect(decoded.body == [.array([]), .array([])])
  }

  @Test(
    "GetLayout's exact reply signature is u(ia{sv}av), never u(iayay) — the literal bug that disconnected real dbusmenu clients"
  )
  func getLayoutReplySignatureMatchesTheDbusmenuContract() {
    let items = [DBusMenuItem(id: 1, label: "Open Clipnest")]
    let body = DBusMenuLayoutBuilder.getLayoutReply(items: items)
    let message = DBusMessage(type: .methodReturn, serial: 1, replySerial: 1, body: body)
    #expect(message.signature == "u(ia{sv}av)")

    let encoded = message.encoded()
    guard let (decoded, consumed) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode GetLayout's own reply")
      return
    }
    #expect(consumed == encoded.count)
    #expect(decoded.signature == "u(ia{sv}av)")
  }
}
