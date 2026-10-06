import Foundation

/// Parses the raw bytes of an ICCCM `WM_CLASS` property: two consecutive
/// null-terminated Latin-1 strings, `"<instance>\0<class>\0"`. Pure byte
/// parsing — no I/O, no X11.
///
/// Per this task's directive, callers use the CLASS (second string, the
/// application's general resource class, e.g. `"Firefox"`), never the
/// instance (the first string, an often-per-window/per-invocation name).
public enum WMClassParser {
  public struct Result: Equatable, Sendable {
    public let instanceName: String
    public let className: String

    public init(instanceName: String, className: String) {
      self.instanceName = instanceName
      self.className = className
    }
  }

  /// Returns `nil` if `bytes` doesn't contain at least two null-terminated
  /// components (a malformed or empty property).
  public static func parse(_ bytes: [UInt8]) -> Result? {
    guard let firstNull = bytes.firstIndex(of: 0) else { return nil }
    let instanceBytes = bytes[bytes.startIndex..<firstNull]
    let remainder = bytes[(firstNull + 1)...]
    guard let secondNull = remainder.firstIndex(of: 0) else { return nil }
    let classBytes = remainder[remainder.startIndex..<secondNull]

    guard let instanceName = String(bytes: instanceBytes, encoding: .isoLatin1),
      let className = String(bytes: classBytes, encoding: .isoLatin1),
      !className.isEmpty
    else { return nil }

    return Result(instanceName: instanceName, className: className)
  }
}
