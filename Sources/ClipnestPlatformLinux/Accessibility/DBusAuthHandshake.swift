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

  /// Sent after `AUTH` succeeds but before `BEGIN`, on a UNIX-domain-socket
  /// transport, to ask the server to allow `SCM_RIGHTS` file-descriptor
  /// passing on this connection (D-Bus Specification, "Authentication" —
  /// the `NEGOTIATE_UNIX_FD`/`AGREE_UNIX_FD` exchange). Without this, a
  /// connection is never fd-capable: the daemon silently refuses to relay
  /// any message carrying a `UNIX_FDS` header field over it, even though
  /// the bytes themselves went through fine — a message can look
  /// perfectly well-formed on the wire and still be dropped for exactly
  /// this reason. Every real D-Bus client library sends this
  /// unconditionally for every connection it opens over a UNIX socket
  /// (never lazily, only on a connection's first fd-carrying call), and
  /// `DBusConnection.performExternalAuth()` does the same.
  static let negotiateUnixFDLine = "NEGOTIATE_UNIX_FD\r\n"

  /// The server's line on agreeing to fd passing is `AGREE_UNIX_FD\r\n`; a
  /// server that doesn't support it replies `ERROR\r\n` instead (never a
  /// silent drop at the SASL layer — the daemon still speaks the line
  /// protocol correctly either way).
  static func isUnixFDAgreed(serverLine: String) -> Bool {
    serverLine.trimmingCharacters(in: .whitespacesAndNewlines) == "AGREE_UNIX_FD"
  }
}
