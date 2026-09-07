import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// Round-trips `DBusValue`s through `DBusByteWriter`/`DBusByteReader` —
/// the strongest possible check on the marshalling layer's alignment
/// arithmetic, since a byte miscount in either direction breaks the
/// round trip rather than merely producing a plausible-looking but wrong
/// answer.
@Suite("DBus marshalling round trip")
struct DBusMarshallingRoundTripTests {
  private func roundTrip(_ value: DBusValue, as type: DBusTypeSignature) -> DBusValue? {
    var writer = DBusByteWriter()
    writer.write(value)
    var reader = DBusByteReader(bytes: writer.bytes)
    return reader.read(type)
  }

  @Test("scalars round-trip")
  func scalarsRoundTrip() {
    #expect(roundTrip(.byte(0xAB), as: .byte) == .byte(0xAB))
    #expect(roundTrip(.boolean(true), as: .boolean) == .boolean(true))
    #expect(roundTrip(.boolean(false), as: .boolean) == .boolean(false))
    #expect(roundTrip(.int32(-42), as: .int32) == .int32(-42))
    #expect(roundTrip(.uint32(4_000_000_000), as: .uint32) == .uint32(4_000_000_000))
    #expect(roundTrip(.int64(-9_000_000_000_000), as: .int64) == .int64(-9_000_000_000_000))
    #expect(roundTrip(.double(3.14159), as: .double) == .double(3.14159))
  }

  @Test("strings and object paths round-trip, including non-ASCII")
  func stringsRoundTrip() {
    #expect(roundTrip(.string("hello"), as: .string) == .string("hello"))
    #expect(roundTrip(.string("héllo 🎉"), as: .string) == .string("héllo 🎉"))
    #expect(roundTrip(.string(""), as: .string) == .string(""))
    #expect(
      roundTrip(.objectPath("/org/a11y/bus"), as: .objectPath) == .objectPath("/org/a11y/bus"))
  }

  @Test("signature values round-trip")
  func signatureRoundTrips() {
    #expect(roundTrip(.signature("(ii)"), as: .signature) == .signature("(ii)"))
  }

  @Test("a struct of two int32s round-trips (GetSelection's (ii) reply shape)")
  func structRoundTrips() {
    let value = DBusValue.structure([.int32(3), .int32(9)])
    #expect(roundTrip(value, as: .structure([.int32, .int32])) == value)
  }

  @Test("an array of strings round-trips")
  func arrayOfStringsRoundTrips() {
    let value = DBusValue.array([.string("a"), .string("bb"), .string("ccc")])
    #expect(roundTrip(value, as: .array(.string)) == value)
  }

  @Test("an empty array round-trips")
  func emptyArrayRoundTrips() {
    let value = DBusValue.array([])
    let result = roundTrip(value, as: .array(.string))
    #expect(result == value)
  }

  @Test("a variant wrapping a string round-trips")
  func variantRoundTrips() {
    #expect(roundTrip(.variant(.string("x")), as: .variant) == .variant(.string("x")))
    #expect(roundTrip(.variant(.int32(5)), as: .variant) == .variant(.int32(5)))
  }

  @Test("an array of struct(byte, variant) round-trips (the D-Bus header-fields shape)")
  func arrayOfHeaderFieldStructsRoundTrips() {
    let value = DBusValue.array([
      .structure([.byte(1), .variant(.objectPath("/a/b"))]),
      .structure([.byte(6), .variant(.string("org.a11y.Bus"))]),
    ])
    let result = roundTrip(value, as: .array(.structure([.byte, .variant])))
    #expect(result == value)
  }

  @Test("a{sv} (dict of string to variant) round-trips")
  func dictOfStringToVariantRoundTrips() {
    let value = DBusValue.array([
      .dictEntry(.string("key1"), .variant(.int32(1))),
      .dictEntry(.string("key2"), .variant(.string("value"))),
    ])
    let result = roundTrip(value, as: .array(.dictEntry(.string, .variant)))
    #expect(result == value)
  }

  @Test(
    "an array of variants, each wrapping a struct, round-trips — VARIANT's own alignment (1) must not leak into what it wraps"
  )
  func arrayOfVariantsWrappingStructsRoundTrips() {
    // Exactly `com.canonical.dbusmenu`'s `av` children shape (a VARIANT
    // wrapping an `(i, a{sv}, av)` STRUCT). VARIANT's OWN alignment is 1,
    // but the STRUCT it wraps still needs a real 8-byte alignment
    // relative to the MESSAGE START — not to wherever the variant itself
    // happens to start. A prior `DBusByteWriter` design built each
    // array's elements into an ISOLATED sub-buffer (local offset 0) and
    // only aligned the SPLICE POINT to the array's ELEMENT TYPE's own
    // alignment (1, for `VARIANT`) — insufficient once splicing at local
    // offset 0 didn't happen to land on a true 8-aligned message offset,
    // silently shifting every field after the struct's alignment padding.
    // Found via this exact shape failing to round-trip while fixing
    // `DBusValue.emptyArray` for the real `GetLayout` P0 — see
    // `DBusByteWriter`'s own doc comment for the fix (write in place,
    // backpatch the length, no isolated sub-buffer for `.array` anymore).
    let value = DBusValue.array([
      .variant(.structure([.int32(1), .int64(2)])),
      .variant(.structure([.int32(3), .int64(4)])),
    ])
    var writer = DBusByteWriter()
    writer.write(value)
    var reader = DBusByteReader(bytes: writer.bytes)
    #expect(reader.read(.array(.variant)) == value)
  }

  @Test("mixed alignment sequence: byte then int32 then struct forces real padding")
  func mixedAlignmentSequenceRoundTrips() {
    // BYTE at offset 0 (align 1), then a STRUCT (align 8) — the struct's
    // start must skip 7 padding bytes; if the writer/reader disagreed on
    // that padding, this would desync.
    var writer = DBusByteWriter()
    writer.write(.byte(0xFF))
    writer.write(.structure([.int32(1), .int32(2)]))
    var reader = DBusByteReader(bytes: writer.bytes)
    #expect(reader.read(.byte) == .byte(0xFF))
    #expect(reader.read(.structure([.int32, .int32])) == .structure([.int32(1), .int32(2)]))
  }
}
