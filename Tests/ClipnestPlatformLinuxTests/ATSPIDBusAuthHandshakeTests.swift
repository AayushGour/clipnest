import Foundation
import Testing

@testable import ClipnestPlatformLinux

@Suite("DBusAuthHandshake")
struct DBusAuthHandshakeTests {
  @Test("hex-encodes the UID's ASCII decimal digits, not the raw UID bytes")
  func hexEncodesAsciiDigits() {
    // uid 1000 -> ASCII "1000" -> hex 31 30 30 30.
    #expect(DBusAuthHandshake.externalAuthLine(uid: 1000) == "AUTH EXTERNAL 31303030\r\n")
  }

  @Test("uid 0 (root) encodes to a single ASCII digit")
  func encodesUidZero() {
    #expect(DBusAuthHandshake.externalAuthLine(uid: 0) == "AUTH EXTERNAL 30\r\n")
  }

  @Test("recognizes an OK response, with or without a trailing GUID")
  func recognizesOkResponse() {
    #expect(DBusAuthHandshake.isAuthAccepted(serverLine: "OK 1234deadbeef\r\n"))
    #expect(DBusAuthHandshake.isAuthAccepted(serverLine: "OK\r\n"))
  }

  @Test("rejects a REJECTED response")
  func rejectsRejectedResponse() {
    #expect(!DBusAuthHandshake.isAuthAccepted(serverLine: "REJECTED EXTERNAL DBUS_COOKIE_SHA1\r\n"))
  }

  @Test("negotiateUnixFDLine is the exact SASL command the spec defines")
  func negotiateUnixFDLineIsExact() {
    #expect(DBusAuthHandshake.negotiateUnixFDLine == "NEGOTIATE_UNIX_FD\r\n")
  }

  @Test("recognizes AGREE_UNIX_FD, tolerating surrounding whitespace/newlines")
  func recognizesAgreeUnixFD() {
    #expect(DBusAuthHandshake.isUnixFDAgreed(serverLine: "AGREE_UNIX_FD\r\n"))
    #expect(DBusAuthHandshake.isUnixFDAgreed(serverLine: "AGREE_UNIX_FD"))
  }

  @Test("rejects an ERROR response to NEGOTIATE_UNIX_FD (a daemon that doesn't support fd passing)")
  func rejectsErrorResponseToNegotiate() {
    #expect(!DBusAuthHandshake.isUnixFDAgreed(serverLine: "ERROR \"Unknown command\"\r\n"))
  }
}
