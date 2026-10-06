import Foundation

/// Parses the `x-special/gnome-copied-files` payload GNOME Files (Nautilus)
/// puts on the clipboard: a newline-separated operation keyword (`copy` or
/// `cut`) followed by one `file://` URI per line. Pure string parsing — no
/// I/O, no X11.
public enum GnomeCopiedFilesParser {
  public struct Result: Equatable, Sendable {
    public let operation: String
    public let fileURIs: [String]

    public init(operation: String, fileURIs: [String]) {
      self.operation = operation
      self.fileURIs = fileURIs
    }
  }

  /// Parses `raw` (already UTF-8-decoded). Returns `nil` if it has no
  /// operation line at all (empty input). A malformed/empty URI list still
  /// parses successfully with an empty `fileURIs` — that's a legitimate
  /// (if useless) copy, not a parse failure.
  public static func parse(_ raw: String) -> Result? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let firstLine = lines.first else { return nil }
    let operation = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !operation.isEmpty else { return nil }

    let fileURIs =
      lines
      .dropFirst()
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return Result(operation: operation, fileURIs: fileURIs)
  }
}
