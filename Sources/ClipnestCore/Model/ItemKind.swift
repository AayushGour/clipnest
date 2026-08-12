import Foundation

/// The kind of content captured in a `ClipItem`.
///
/// `.image` items store their bytes in `BlobStore` (content-addressed,
/// `ClipItem.blobPath`); `.file` items store only reference metadata (no
/// blob) — see `PasteboardReader`/`ClipboardMonitor` (plan task T20).
public enum ItemKind: String, Codable, CaseIterable, Sendable {
  case text
  case richText
  case link
  case image
  case file
}
