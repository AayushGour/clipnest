// UnavailableImagePixelHasher.swift
//
// P2-E (Linux port): the non-Apple default `ImagePixelHashing` conformance.
// `CoreGraphicsImagePixelHasher` (`Platform/macOS/CoreGraphicsImagePixelHasher.swift`)
// is the only production conformance today, and it's `#if os(macOS)` — its
// canonical-pixel decode/re-render is `CGImageSource`/`CGContext`-based,
// which doesn't exist off Apple platforms (see that file's own P2-C note).
// `PasteboardReader.init`'s `pixelHasher` default named that concrete type
// directly (`= CoreGraphicsImagePixelHasher()`), which is a Linux build
// break even though `PasteboardReader.swift` itself has no Apple imports —
// Swift must resolve every default-argument type at compile time. Routing
// the default through `PlatformDefaults.imagePixelHasher` (this file's
// `#if !os(macOS)` extension below) fixes that without touching
// `PasteboardReader.swift`'s macOS-observed behavior at all.
//
// WHY THIS RETURNS `nil`, NOT A WEAKER HASH (D44):
// `ClipItem.contentHash` for `.image` is deliberately a hash of DECODED
// PIXELS, not encoded bytes, precisely so the same picture captured as PNG
// vs. TIFF still dedups to one row (D44/D45). A lossy, downsampled, or
// otherwise perceptual placeholder hash would violate the one guarantee
// `ImagePixelHashing.swift`'s doc comment states as non-negotiable — "two
// images that differ by even one pixel must never produce the same hash" —
// by colliding two genuinely-different near-identical screenshots and
// silently discarding the second, which is DATA LOSS. That would be worse
// than what this type actually does.
//
// `pixelContentHash(of:)`'s contract already has a safe answer for "can't
// produce a decoded-pixel hash": return `nil`. `PasteboardReader
// .imageContentHash(for:dimensions:)` already handles that outcome — the
// exact same path a real `CoreGraphicsImagePixelHasher` takes for
// undecodable bytes — by falling back to `BlobStore.contentHash(of:)`, the
// raw-byte hash. That fallback is EXACT (no false-dedup risk); it only
// loses format-independence, i.e. a PNG and a TIFF of the same picture
// dedup as two rows on Linux until a real decoder-backed conformance lands,
// never a false collision. So always returning `nil` here is the strictly
// correct placeholder — never inventing a weaker hash.
//
// A real Linux implementation needs a decoded-pixel source, which doesn't
// exist in this codebase yet outside `ImageIO`/`CoreGraphics` — it will
// most likely share whatever decode path the Linux OCR/thumbnail work
// builds (see D47). That's Phase 4 work, explicitly out of scope here.

import Foundation

/// The non-Apple default `ImagePixelHashing` conformance — always returns
/// `nil`. See this file's header comment for why `nil` (not a weaker,
/// lossy hash) is the only correct placeholder pending a real decoder-backed
/// Linux implementation.
///
/// Named honestly: this is NOT "PortableImagePixelHasher" or any other name
/// implying it does the job on non-Apple platforms — it does not, and never
/// should be assumed to. It exists purely so `PlatformDefaults
/// .imagePixelHasher` has *some* non-Apple default to compile against
/// (mirroring `NullRichTextFlattener`'s identical honesty-in-naming
/// rationale), never used in production once a real backend lands.
public struct UnavailableImagePixelHasher: ImagePixelHashing {
  public init() {}

  public func pixelContentHash(of imageData: Data) -> String? {
    nil
  }
}

#if !os(macOS)
  extension PlatformDefaults {
    /// The non-Apple `ImagePixelHashing` default. See
    /// `UnavailableImagePixelHasher`'s doc comment — Linux images dedup by
    /// encoded bytes (`BlobStore.contentHash(of:)`, via `PasteboardReader
    /// .imageContentHash(for:dimensions:)`'s existing `nil`-hasher fallback)
    /// until a real decoder-backed implementation lands in the platform
    /// layer (Phase 4).
    public static var imagePixelHasher: any ImagePixelHashing {
      UnavailableImagePixelHasher()
    }
  }
#endif
