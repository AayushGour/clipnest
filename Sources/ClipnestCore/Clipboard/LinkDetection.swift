import Foundation

/// Decides whether a piece of text is a single, well-formed link. Shared by
/// capture (`PasteboardReader`) and edit re-derivation
/// (`ClipContentDerivation`) so both classify identically.
public enum LinkDetection {
  private static let validLinkSchemes: Set<String> = ["http", "https", "ftp", "mailto"]

  public static func isLink(_ text: String) -> Bool {
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
      return false
    }
    guard validLinkSchemes.contains(scheme) else { return false }
    if scheme == "mailto" { return true }
    return !(url.host?.isEmpty ?? true)
  }
}
