import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("TextPayloadDecoder")
struct TextPayloadDecoderTests {
  @Test("Decodes text/plain;charset=utf-8 as UTF-8")
  func decodesExplicitUTF8() {
    let data = Data("héllo".utf8)
    #expect(TextPayloadDecoder.decode(data, mimeType: "text/plain;charset=utf-8") == "héllo")
  }

  @Test("Decodes UTF8_STRING as UTF-8")
  func decodesUTF8StringAtom() {
    let data = Data("clipboard".utf8)
    #expect(TextPayloadDecoder.decode(data, mimeType: "UTF8_STRING") == "clipboard")
  }

  @Test("Decodes bare text/plain as UTF-8")
  func decodesBareTextPlainAsUTF8() {
    let data = Data("no charset given".utf8)
    #expect(TextPayloadDecoder.decode(data, mimeType: "text/plain") == "no charset given")
  }

  @Test("Decodes the legacy STRING target as Latin-1 (ICCCM 2.6.2), not UTF-8")
  func decodesLegacyStringAsLatin1() {
    // 0xE9 is "é" in Latin-1 but is not valid standalone UTF-8.
    let latin1Bytes = Data([0x68, 0x65, 0xE9])
    #expect(String(data: latin1Bytes, encoding: .utf8) == nil)
    #expect(TextPayloadDecoder.decode(latin1Bytes, mimeType: "STRING") == "he\u{00E9}")
  }

  @Test("Returns nil for bytes that are not valid under the resolved encoding")
  func returnsNilForInvalidBytes() {
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
    #expect(TextPayloadDecoder.decode(invalidUTF8, mimeType: "text/plain") == nil)
  }
}
