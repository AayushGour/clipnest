import Foundation

/// The content-derived fields of a `ClipItem`.
public struct DerivedClipContent: Sendable, Equatable {
  public let kind: ItemKind
  public let previewText: String
  public let contentHash: String
  public let byteSize: Int

  public init(kind: ItemKind, previewText: String, contentHash: String, byteSize: Int) {
    self.kind = kind
    self.previewText = previewText
    self.contentHash = contentHash
    self.byteSize = byteSize
  }
}

/// Single definition of how `kind`/`previewText`/`contentHash`/`byteSize` are
/// derived from content. Used by capture (`PasteboardReader`) and by item
/// editing, so an edited item is indistinguishable from a freshly captured one.
public enum ClipContentDerivation {
  /// Preview is trimmed; hash and size come from the UNTRIMMED UTF-8 bytes
  /// (exactly what capture does). A single URL becomes `.link`.
  public static func plainText(_ text: String) -> DerivedClipContent {
    let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = Data(text.utf8)
    return DerivedClipContent(
      kind: LinkDetection.isLink(preview) ? .link : .text,
      previewText: preview,
      contentHash: BlobStore.contentHash(of: data),
      byteSize: data.count)
  }

  /// Preview is the trimmed `plainText`; hash and size describe the rich blob.
  public static func richText(blob: Data, plainText: String) -> DerivedClipContent {
    DerivedClipContent(
      kind: .richText,
      previewText: plainText.trimmingCharacters(in: .whitespacesAndNewlines),
      contentHash: BlobStore.contentHash(of: blob),
      byteSize: blob.count)
  }
}
