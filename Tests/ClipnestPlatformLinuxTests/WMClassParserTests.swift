import Testing

@testable import ClipnestPlatformLinux

@Suite("WMClassParser")
struct WMClassParserTests {
  private func bytes(_ instance: String, _ className: String) -> [UInt8] {
    Array(instance.utf8) + [0] + Array(className.utf8) + [0]
  }

  @Test("Parses instance and class from a well-formed WM_CLASS property")
  func parsesInstanceAndClass() {
    let result = WMClassParser.parse(bytes("firefox", "Firefox"))
    #expect(result?.instanceName == "firefox")
    #expect(result?.className == "Firefox")
  }

  @Test("Trailing bytes after the second null are ignored")
  func ignoresTrailingBytes() {
    var raw = bytes("code", "Code")
    raw.append(contentsOf: [0x00, 0x01, 0x02])
    let result = WMClassParser.parse(raw)
    #expect(result?.className == "Code")
  }

  @Test("Returns nil when there is no null terminator at all")
  func returnsNilWithNoNullTerminator() {
    #expect(WMClassParser.parse(Array("noterminator".utf8)) == nil)
  }

  @Test("Returns nil when only the instance is null-terminated (no class string)")
  func returnsNilWithOnlyOneComponent() {
    #expect(WMClassParser.parse(Array("instance".utf8) + [0]) == nil)
  }

  @Test("Returns nil when the class component is empty")
  func returnsNilForEmptyClass() {
    #expect(WMClassParser.parse(bytes("instance", "")) == nil)
  }

  @Test("Returns nil for empty input")
  func returnsNilForEmptyInput() {
    #expect(WMClassParser.parse([]) == nil)
  }
}
