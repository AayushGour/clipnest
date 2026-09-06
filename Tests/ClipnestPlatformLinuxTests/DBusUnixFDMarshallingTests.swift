import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// Pure marshalling coverage for `DBusValue.unixFD` (task P8-C) — the D-Bus
/// wire format's `h` type code. None of this needs a real socket or a real
/// bus: `UNIX_FD` is marshalled EXACTLY like `UINT32` on the wire (a plain
/// 4-byte little-endian index, 4-byte aligned), so every check here is the
/// same kind of pure byte-level round trip `DBusMarshallingRoundTripTests`/
/// `DBusMessageTests` already use for every other type. Whether a real
/// `SCM_RIGHTS` file descriptor genuinely survives a round trip is proven
/// separately: `DBusFileDescriptorPassingTests` (a real `socketpair(2)`,
/// still fully automatable in CI) and, going further, a real session-bus
/// daemon in a container (this task's manual verification — see
/// `DBusConnection`'s own doc comment on why THAT layer stays
/// manual-verify-only).
@Suite("DBusValue.unixFD marshalling")
struct DBusUnixFDMarshallingTests {
  @Test("an .unixFD value round-trips through DBusByteWriter/DBusByteReader as a plain UINT32")
  func unixFDRoundTripsAsUInt32() {
    var writer = DBusByteWriter()
    writer.write(.unixFD(0))
    var reader = DBusByteReader(bytes: writer.bytes)
    #expect(reader.read(.unixFD) == .unixFD(0))

    var writer2 = DBusByteWriter()
    writer2.write(.unixFD(3))
    var reader2 = DBusByteReader(bytes: writer2.bytes)
    #expect(reader2.read(.uint32) == .uint32(3), "on the wire, .unixFD(3) IS .uint32(3)")
  }

  @Test("signatureCode is \"h\", and DBusSignatureParser round-trips it, alone and compound")
  func signatureCodeAndParsingRoundTrip() {
    #expect(DBusValue.unixFD(0).signatureCode == "h")
    #expect(DBusSignatureParser.parse("h") == [.unixFD])
    #expect(DBusSignatureParser.parse("sh") == [.string, .unixFD])
    #expect(DBusSignatureParser.parse("ah") == [.array(.unixFD)])
  }

  @Test("UNIX_FD aligns to 4 bytes, exactly like UINT32 — both DBusValue and DBusTypeSignature")
  func alignmentMatchesUInt32() {
    #expect(DBusValue.unixFD(0).alignment == 4)
    #expect(DBusTypeSignature.unixFD.alignment == 4)
  }

  @Test("a byte followed by an .unixFD forces the same 3-byte pad a byte-then-uint32 would")
  func mixedAlignmentSequenceRoundTrips() {
    var writer = DBusByteWriter()
    writer.write(.byte(0xFF))
    writer.write(.unixFD(7))
    // BYTE at offset 0, then 3 bytes of padding, then the 4-byte index at
    // offset 4 — 8 bytes total. If the writer/reader disagreed about that
    // padding, the round trip below would desync and read garbage.
    #expect(writer.bytes.count == 8)
    var reader = DBusByteReader(bytes: writer.bytes)
    #expect(reader.read(.byte) == .byte(0xFF))
    #expect(reader.read(.unixFD) == .unixFD(7))
  }

  @Test("an array of .unixFD indices round-trips (a hypothetical multi-fd method)")
  func arrayOfUnixFDsRoundTrips() {
    let value = DBusValue.array([.unixFD(0), .unixFD(1), .unixFD(2)])
    var writer = DBusByteWriter()
    writer.write(value)
    var reader = DBusByteReader(bytes: writer.bytes)
    #expect(reader.read(.array(.unixFD)) == value)
  }

  @Test("DBusMessage defaults unixFileDescriptorCount to 0 and emits no UNIX_FDS header field")
  func defaultsToNoHeaderField() {
    let message = DBusMessage(
      type: .methodCall, serial: 1, path: "/a", member: "M", body: [.string("x")])
    #expect(message.unixFileDescriptorCount == 0)
    guard let (decoded, _) = DBusMessage.decode(message.encoded()) else {
      Issue.record("failed to decode")
      return
    }
    #expect(decoded.unixFileDescriptorCount == 0)
  }

  @Test("DBusMessage.encoded() emits UNIX_FDS with the right count, and decode reads it back")
  func unixFDsHeaderFieldRoundTrips() {
    // SetClipboard(mimetype, fd)-shaped: one string, one fd index, one
    // real descriptor attached.
    let message = DBusMessage(
      type: .methodCall, serial: 5, path: "/app/clipnest/ShellHelper",
      interface: "app.clipnest.ShellHelper1", member: "SetClipboard",
      destination: "app.clipnest.ShellHelper", body: [.string("text/plain"), .unixFD(0)],
      unixFileDescriptorCount: 1)
    let encoded = message.encoded()
    guard let (decoded, consumed) = DBusMessage.decode(encoded) else {
      Issue.record("failed to decode")
      return
    }
    #expect(consumed == encoded.count)
    #expect(decoded.unixFileDescriptorCount == 1)
    #expect(decoded.body == [.string("text/plain"), .unixFD(0)])
  }

  @Test("a message with several attached fds round-trips the exact count")
  func multipleAttachedFileDescriptorsCountRoundTrips() {
    let message = DBusMessage(
      type: .methodReturn, serial: 9, replySerial: 5, body: [.unixFD(0), .unixFD(1)],
      unixFileDescriptorCount: 2)
    guard let (decoded, _) = DBusMessage.decode(message.encoded()) else {
      Issue.record("failed to decode")
      return
    }
    #expect(decoded.unixFileDescriptorCount == 2)
  }

  @Test("UNIX_FDS survives alongside every other header field, unordered decode")
  func unixFDsCoexistsWithOtherHeaderFields() {
    let message = DBusMessage(
      type: .methodCall, serial: 42, path: "/app/clipnest/ShellHelper",
      interface: "app.clipnest.ShellHelper1", member: "ReadClipboard",
      destination: "app.clipnest.ShellHelper", sender: ":1.7",
      body: [.uint32(3), .string("image/png")],
      unixFileDescriptorCount: 0)
    guard let (decoded, _) = DBusMessage.decode(message.encoded()) else {
      Issue.record("failed to decode")
      return
    }
    #expect(decoded.path == "/app/clipnest/ShellHelper")
    #expect(decoded.interface == "app.clipnest.ShellHelper1")
    #expect(decoded.member == "ReadClipboard")
    #expect(decoded.destination == "app.clipnest.ShellHelper")
    #expect(decoded.sender == ":1.7")
    #expect(decoded.unixFileDescriptorCount == 0)
    #expect(decoded.body == [.uint32(3), .string("image/png")])
  }
}
