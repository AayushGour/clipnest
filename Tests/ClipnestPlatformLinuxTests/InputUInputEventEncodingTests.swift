import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("UInputEventEncoding")
struct UInputEventEncodingTests {
  @Test("input_event is exactly 24 bytes: 16 zero timestamp + type + code + value, little-endian")
  func encodesInputEventLayout() {
    let bytes = UInputEventEncoding.encodeInputEvent(type: 0x01, code: 0x2F, value: 1)
    #expect(bytes.count == UInputEventEncoding.inputEventByteCount)
    #expect(bytes.count == 24)
    #expect(Array(bytes[0..<16]) == [UInt8](repeating: 0, count: 16))
    #expect(bytes[16] == 0x01 && bytes[17] == 0x00)  // type, little-endian UInt16
    #expect(bytes[18] == 0x2F && bytes[19] == 0x00)  // code, little-endian UInt16
    #expect(bytes[20] == 0x01 && bytes[21] == 0 && bytes[22] == 0 && bytes[23] == 0)  // value=1
  }

  @Test("a key-up event (value 0) encodes all-zero value bytes")
  func encodesKeyUpValue() {
    let bytes = UInputEventEncoding.encodeInputEvent(type: 0x01, code: 0x2F, value: 0)
    #expect(Array(bytes[20..<24]) == [0, 0, 0, 0])
  }

  @Test("device setup encodes input_id + name + ff_effects_max at the right offsets")
  func encodesDeviceSetupLayout() {
    let bytes = UInputEventEncoding.encodeDeviceSetup(
      busType: 0x06, vendor: 0, product: 0, version: 1, name: "Clipnest Virtual Keyboard",
      ffEffectsMax: 0)
    // input_id: 4 * UInt16 = 8 bytes.
    #expect(bytes[0] == 0x06 && bytes[1] == 0x00)  // bustype
    #expect(bytes[6] == 0x01 && bytes[7] == 0x00)  // version
    let nameBytes = Array(bytes[8..<(8 + UInputEventEncoding.maxDeviceNameByteCount)])
    let nameString = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
    #expect(nameString == "Clipnest Virtual Keyboard")
    // Remaining name buffer bytes are NUL-padded.
    #expect(nameBytes.last == 0)
    #expect(bytes.count == UInputDeviceSetupLayout.byteCount)
  }

  @Test("an over-long device name is truncated, never overflows the fixed buffer")
  func truncatesOverlongName() {
    let longName = String(repeating: "x", count: 200)
    let bytes = UInputEventEncoding.encodeDeviceSetup(
      busType: 0, vendor: 0, product: 0, version: 0, name: longName, ffEffectsMax: 0)
    #expect(bytes.count == UInputDeviceSetupLayout.byteCount)
  }
}
