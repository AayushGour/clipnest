import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("DBusAddress")
struct DBusAddressTests {
  @Test("parses a unix:path= address")
  func parsesPathAddress() {
    let result = DBusAddress.parseFirstUnixTarget(
      "unix:path=/run/user/1000/bus,guid=abc123")
    #expect(result == .path("/run/user/1000/bus"))
  }

  @Test("parses a unix:abstract= address")
  func parsesAbstractAddress() {
    let result = DBusAddress.parseFirstUnixTarget("unix:abstract=/tmp/dbus-XXXXXX,guid=abc")
    #expect(result == .abstract("/tmp/dbus-XXXXXX"))
  }

  @Test("takes only the first address in a semicolon-separated list")
  func takesFirstOfMultiple() {
    let result = DBusAddress.parseFirstUnixTarget(
      "unix:path=/run/first;unix:path=/run/second")
    #expect(result == .path("/run/first"))
  }

  @Test("percent-decodes reserved characters in the value")
  func percentDecodesValue() {
    let result = DBusAddress.parseFirstUnixTarget("unix:path=/tmp/has%20space")
    #expect(result == .path("/tmp/has space"))
  }

  @Test("returns nil for a non-unix transport")
  func rejectsNonUnixTransport() {
    #expect(DBusAddress.parseFirstUnixTarget("tcp:host=localhost,port=1234") == nil)
  }

  @Test("returns nil for a malformed address")
  func rejectsMalformedAddress() {
    #expect(DBusAddress.parseFirstUnixTarget("") == nil)
    #expect(DBusAddress.parseFirstUnixTarget("unix:") == nil)
  }
}
