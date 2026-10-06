// ItemPreviewContent.swift
//
// P11-D (Linux port, GTK4 view layer): pure preview-content decisions for
// the hover/selection popover — everything `PickerWindow+Preview.swift`
// (the untestable GTK edge) needs to know about WHAT to show for a given
// `ClipItem`, computed once up front so the GTK-touching code only ever
// does dumb "set this label's text"/"show this widget" calls. Mirrors
// `ClipItemRowContent`'s established split in this same directory (pure
// content model vs. the GTK code that renders it).
//
// Content mirrors macOS `ItemPreview.content` (`ClipnestApp/Sources/UI/
// Picker/ItemPreview.swift`) exactly:
//   - `.image`     → no caption text at all (only the image itself, plus an
//                    optional recognized-text section below it — T-OCR2).
//   - `.file`      → a filename headline (`previewText`) plus, when
//                    resolvable, the file's abbreviated on-disk path.
//   - `.text`/`.richText`/`.link` → `previewText` verbatim.
//
// Deliberately does NOT include the file's byte size: unlike everything
// else here, that requires a live `stat()` (macOS's `FilePreview` reads it
// off-main via `FileManager.default.attributesOfItem(atPath:)`, since
// `PasteboardReader.readFile`'s doc comment explains capture never reads it
// — `ClipItem.byteSize` is always 0 for `.file`). A pure struct can't do
// I/O, so that stays a separate step in `PickerWindow+Preview.swift`
// (`updateFilePreviewMetadata`), matching this file's own `ClipItemRowContent`
// precedent of keeping I/O (`decodeBoundedThumbnail`) out of the pure model.
import ClipnestCore
import Foundation

public struct ItemPreviewContent: Equatable, Sendable {
  public let kind: ItemKind
  /// The primary text label: `previewText` for `.text`/`.richText`/`.link`/
  /// `.file` (the `.file` headline), `nil` for `.image` — see this file's
  /// top doc comment for why `.image` shows no caption at all.
  public let bodyText: String?
  /// `.file` only — `fileReference`'s path, abbreviated with `~` for the
  /// user's home directory, or `nil` when `fileReference` isn't a
  /// resolvable local file URL. Always `nil` for every other kind.
  public let filePath: String?
  /// Mirrors `ClipItem.hasRecognizedText` — `true` only for an `.image`
  /// with non-empty `ocrText`.
  public let hasRecognizedText: Bool
  /// The recognized text itself, kept in lockstep with `hasRecognizedText`
  /// (`nil` whenever that's `false`) so a caller never needs to re-check
  /// both independently.
  public let ocrText: String?

  public init(item: ClipItem) {
    kind = item.kind
    switch item.kind {
    case .image:
      bodyText = nil
    case .text, .richText, .link, .file:
      bodyText = item.previewText
    }
    filePath = item.kind == .file ? Self.abbreviatedFilePath(item.fileReference) : nil
    hasRecognizedText = item.hasRecognizedText
    ocrText = item.hasRecognizedText ? item.ocrText : nil
  }

  /// Mirrors macOS `FilePreview.filePath`'s `(url.path as NSString)
  /// .abbreviatingWithTildeInPath` without relying on that NSString method
  /// (unverified on Linux's `swift-corelibs-foundation`) — a plain prefix
  /// swap against `NSHomeDirectory()` covers the identical common case (the
  /// file living somewhere under the user's home directory) with no
  /// platform-specific API at all.
  static func abbreviatedFilePath(_ reference: String?) -> String? {
    guard let reference, let url = URL(string: reference), url.isFileURL else { return nil }
    let path = url.path
    let home = NSHomeDirectory()
    guard !home.isEmpty, path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
  }
}
