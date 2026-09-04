// RGBAPixelFormat.swift
//
// T-PF6 (review cleanup): "4 bytes per RGBA pixel" (1 byte each for red,
// green, blue, alpha, at 8 bits/component) was independently duplicated as
// three separately-named constants: `CoreGraphicsImagePixelHasher
// .canonicalBytesPerPixel`, `ImageThumbnailDecoder.bytesPerPixelEstimate`
// (`ClipnestApp`), and an inline `* 4` in `ItemRow.ItemIconThumbnail
// .approximateByteCost` (`ClipnestApp`). Unlike the capture/OCR size
// ceilings (see `PasteboardReader.maxCapturedImageByteSize`/
// `VisionTextRecognizer.maxByteSize`'s doc comments for why THOSE stay
// deliberately separate), this one is a single fact about the RGBA8 pixel
// format itself — not an independently-tunable policy. The three sites can
// never legitimately diverge (they're all describing the same "4 bytes per
// pixel" bitmap layout), so collapsing them here removes real duplication
// rather than introducing false coupling.
//
// Lives in `ClipnestCore/Media/` (matching `CoreGraphicsImagePixelHasher`'s
// and `ImagePixelHashing`'s home), not `ClipnestApp`, so both modules can
// share it — `ClipnestApp` already depends on `ClipnestCore` and imports it
// in every file that references this constant. Same "single shared source of
// truth" pattern `ClipnestLog.subsystem` (`Logging.swift`) already
// established for a cross-module constant.

/// Describes the 8-bit-per-component RGBA bitmap layout Clipnest's image
/// code standardizes on for canonical hashing (`CoreGraphicsImagePixelHasher`)
/// and for `NSCache` cost estimates of decoded bitmaps
/// (`ImageThumbnailDecoder`, `ItemRow`'s `ItemIconThumbnail`).
public enum RGBAPixelFormat {
  /// Bytes one pixel occupies: 1 byte each for red, green, blue, and alpha
  /// at 8 bits/component. The single source of truth for every "4 bytes per
  /// pixel" computation in the codebase — see this file's doc comment.
  public static let bytesPerPixel = 4
}
