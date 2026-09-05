import Foundation

/// Builds/parses the plain-text SASL lines D-Bus's `EXTERNAL` auth
/// mechanism exchanges before a connection switches to the binary message
/// protocol — pure string logic, no socket I/O (that's `DBusConnection`).
///
/// `EXTERNAL` identifies the connecting process by its already-verified
/// (kernel `SO_PEERCRED`-checked) UID, which is exactly what every local
/// same-machine D-Bus connection this module makes wants — no password,
/// no cookie file, no crypto handshake, unlike the other SASL mechanisms
/// the spec allows.
enum DBusAuthHandshake {
  /// The initial NUL byte the D-Bus spec requires as the very first byte
  /// sent on a new connection, before any AUTH command.
  static let initialNulByte: UInt8 = 0

  /// D-Bus requires the UID for `AUTH EXTERNAL` hex-encoded as the ASCII
  /// decimal string of the UID (NOT the raw UID's bytes) — e.g. uid 1000
  /// becomes the ASCII text "1000", which is then hex-encoded byte-by-byte
  /// to "31303030".
  static func externalAuthLine(uid: UInt32) -> String {
    let decimalDigits = String(uid)
    let hexEncoded = decimalDigits.utf8.map { byte in
      String(format: "%02x", byte)
    }.joined()
    return "AUTH EXTERNAL \(hexEncoded)\r\n"
  }

  static let beginLine = "BEGIN\r\n"

  /// The server's line on successful auth is `OK <server-guid>\r\n`.
  static func isAuthAccepted(serverLine: String) -> Bool {
    let trimmed = serverLine.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "OK" || trimmed.hasPrefix("OK ")
  }
}
