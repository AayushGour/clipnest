import Foundation

/// The two `unix:` transport address shapes this module ever connects to —
/// the session bus (`DBUS_SESSION_BUS_ADDRESS`, almost always
/// `unix:path=...` on modern systemd-based distros) and the AT-SPI bus
/// (the address `org.a11y.Bus.GetAddress` returns, commonly
/// `unix:abstract=...`).
public enum DBusSocketTarget: Equatable, Sendable {
  case path(String)
  case abstract(String)
}

/// Parses D-Bus server address strings (the D-Bus Specification's
/// "Server Addresses" grammar) — pure, no socket I/O. Only the `unix:`
/// transport is supported, since it's the only one any of this module's
/// targets (session bus, a11y bus) ever use.
public enum DBusAddress {
  /// Parses the FIRST address in a (possibly semicolon-separated list of)
  /// D-Bus address string.
  public static func parseFirstUnixTarget(_ address: String) -> DBusSocketTarget? {
    guard let firstAddress = address.split(separator: ";", maxSplits: 1).first else { return nil }
    guard firstAddress.hasPrefix("unix:") else { return nil }
    let parameters = firstAddress.dropFirst("unix:".count)
    for pair in parameters.split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let key = String(parts[0])
      let value = percentDecode(String(parts[1]))
      if key == "path" { return .path(value) }
      if key == "abstract" { return .abstract(value) }
    }
    return nil
  }

  /// D-Bus addresses percent-encode reserved characters in their parameter
  /// values (the spec's "Rules for Escaping" section, similar to RFC 3986)
  /// — decode before using the result as a real filesystem path or
  /// abstract-socket name.
  static func percentDecode(_ value: String) -> String {
    value.removingPercentEncoding ?? value
  }
}
