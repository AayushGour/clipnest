import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("DBusSignatureParser")
struct DBusSignatureParserTests {
  @Test("parses simple scalar signatures")
  func parsesScalars() {
    #expect(DBusSignatureParser.parse("s") == [.string])
    #expect(DBusSignatureParser.parse("i") == [.int32])
    #expect(DBusSignatureParser.parse("b") == [.boolean])
    #expect(DBusSignatureParser.parse("") == [])
  }

  @Test("parses a sequence of top-level args")
  func parsesSequence() {
    #expect(DBusSignatureParser.parse("isi") == [.int32, .string, .int32])
  }

  @Test("parses a struct")
  func parsesStruct() {
    #expect(DBusSignatureParser.parse("(ii)") == [.structure([.int32, .int32])])
  }

  @Test("parses an array of a scalar")
  func parsesArrayOfScalar() {
    #expect(DBusSignatureParser.parse("as") == [.array(.string)])
  }

  @Test("parses a dict-entry array (a{sv})")
  func parsesDictEntryArray() {
    #expect(DBusSignatureParser.parse("a{sv}") == [.array(.dictEntry(.string, .variant))])
  }

  @Test("parses the AT-SPI StateChanged signal signature siiva{sv}")
  func parsesStateChangedSignature() {
    #expect(
      DBusSignatureParser.parse("siiva{sv}")
        == [
          .string, .int32, .int32, .variant, .array(.dictEntry(.string, .variant)),
        ])
  }

  @Test("parses nested structs")
  func parsesNestedStruct() {
    #expect(
      DBusSignatureParser.parse("(s(ii))") == [.structure([.string, .structure([.int32, .int32])])]
    )
  }

  @Test("malformed signatures return nil rather than guessing")
  func malformedReturnsNil() {
    #expect(DBusSignatureParser.parse("(ii") == nil)
    #expect(DBusSignatureParser.parse("a") == nil)
    #expect(DBusSignatureParser.parse("{sv}") == nil)
    #expect(DBusSignatureParser.parse("Z") == nil)
  }
}
