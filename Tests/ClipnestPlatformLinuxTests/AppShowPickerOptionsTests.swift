import ClipnestPlatformLinux
import Foundation
import Testing

@testable import ClipnestLinuxAppKit

@Suite("ShowPickerOptions")
struct AppShowPickerOptionsTests {
  @Test("parse extracts pointer-x/pointer-y/monitor from an a{sv} dict")
  func parseExtractsPointerAndMonitor() {
    let value: DBusValue = .array([
      .dictEntry(.string("pointer-x"), .variant(.int32(100))),
      .dictEntry(.string("pointer-y"), .variant(.int32(200))),
      .dictEntry(.string("monitor"), .variant(.int32(2))),
    ])
    let options = ShowPickerOptions.parse(value)
    #expect(options.pointer?.x == 100)
    #expect(options.pointer?.y == 200)
    #expect(options.monitor == 2)
  }

  @Test("parse requires BOTH pointer-x and pointer-y — a lone one never yields a half point")
  func parseRequiresBothCoordinates() {
    let onlyX: DBusValue = .array([.dictEntry(.string("pointer-x"), .variant(.int32(5)))])
    #expect(ShowPickerOptions.parse(onlyX).pointer == nil)
  }

  @Test("parse of a non-array value degrades to .empty rather than crashing")
  func parseOfWrongShapeDegradesToEmpty() {
    #expect(ShowPickerOptions.parse(.string("not a dict")) == .empty)
  }

  @Test("parse ignores unrecognized keys")
  func parseIgnoresUnrecognizedKeys() {
    let value: DBusValue = .array([
      .dictEntry(.string("something-else"), .variant(.string("ignored")))
    ])
    #expect(ShowPickerOptions.parse(value) == .empty)
  }

  @Test("encoded() then parse() round-trips pointer and monitor")
  func roundTripsPointerAndMonitor() {
    let original = ShowPickerOptions(pointer: (x: 42, y: 7), monitor: 0, focusKeys: [])
    let roundTripped = ShowPickerOptions.parse(original.encoded())
    #expect(roundTripped.pointer?.x == 42)
    #expect(roundTripped.pointer?.y == 7)
    #expect(roundTripped.monitor == 0)
  }

  @Test("encoded() then parse() round-trips focus keys")
  func roundTripsFocusKeys() {
    let original = ShowPickerOptions(pointer: nil, monitor: nil, focusKeys: ["app-id", "title"])
    let roundTripped = ShowPickerOptions.parse(original.encoded())
    #expect(Set(roundTripped.focusKeys) == Set(["app-id", "title"]))
  }
}
