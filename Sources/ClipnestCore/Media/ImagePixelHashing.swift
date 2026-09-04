// ImagePixelHashing.swift
//
// T-PF5a: abstraction over format-independent, decoded-pixel-content
// hashing for a captured image's raw bytes. Mirrors `OCR/TextRecognizing
// .swift`'s injectable-protocol pattern (coding-standards.md's testing
// rules: prefer a protocol boundary over a hard call to a system-framework
// decoder), and lives in a new `Media/` folder — not `Clipboard/`, not
// `OCR/` — because both `Clipboard/` (capture-time dedup) and `Store/`
// (backfill/migration of already-stored items) need this, and neither
// owns the other.
//
// Why this exists: `ClipItem.contentHash` was SHA-256 over the RAW CAPTURED
// BYTES (`PasteboardReader.swift` → `BlobStore.contentHash(of:)`). Once
// image capture started preferring PNG over TIFF, the SAME picture could
// hash differently purely because of which container the source app
// happened to offer, breaking dedup. `ImagePixelHashing` fixes that at the
// root: hash the DECODED PIXEL CONTENT, re-rendered into one canonical
// format, so the container never affects the digest.
//
// The safety property that matters most: NO FALSE DEDUP. Two images that
// differ by even one pixel must never produce the same hash — that would
// silently discard the second copy as a "duplicate," which is data loss,
// strictly worse than the format-dependent duplicate row this task fixes.
// This is why `CoreGraphicsImagePixelHasher` (the production conformance)
// hashes the FULL-RESOLUTION canonical pixel buffer — never a perceptual,
// downsampled, or otherwise lossy digest.

import Foundation

/// Produces a format-independent content hash over an image's DECODED PIXEL
/// CONTENT — never the raw encoded container bytes — so the same picture
/// hashes identically regardless of whether it arrived as PNG, TIFF, or any
/// other `ImageIO`-decodable container.
public protocol ImagePixelHashing: Sendable {
  /// Returns a lowercase-hex content hash over `imageData`'s decoded,
  /// canonicalized pixel content, or `nil` when `imageData` can't be
  /// decoded as an image. Callers fall back to a raw-byte hash
  /// (`BlobStore.contentHash(of:)`) in that `nil` case — this protocol
  /// never throws, matching `TextRecognizing`'s "failure is just `nil`,
  /// never a crash or a propagated error" contract, since a hashing
  /// failure must never block capture/storage of an otherwise-valid item.
  func pixelContentHash(of imageData: Data) -> String?
}
