import Foundation

#if os(macOS)
  import ImageIO

  /// Production `ImageMetadataProbing` conformance — the exact
  /// `ImageIO`-backed body `PasteboardReader.imagePixelDimensions(for:)`
  /// used to run inline, extracted verbatim behind the protocol seam by
  /// the Linux port (P2-A) so macOS behavior stays byte-identical (frozen
  /// per D47) while the shared file compiles without `ImageIO` elsewhere.
  ///
  /// T-PERF1: reads pixel dimensions via `ImageIO`'s
  /// `CGImageSourceCopyPropertiesAtIndex` instead of the older
  /// `NSBitmapImageRep(data:)` — this runs inside `PasteboardReader
  /// .classify(_:)`, off `@MainActor` (`NSImage`/its AppKit siblings
  /// aren't documented thread-safe for every operation; `ImageIO`'s plain
  /// C API is). Reading just the properties dictionary (a small header
  /// parse) instead of decoding full pixel data is also strictly cheaper.
  public struct MacImageMetadataProbe: ImageMetadataProbing {
    public init() {}

    public func pixelDimensions(of imageData: Data) -> (width: Int, height: Int)? {
      guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0
      else {
        return nil
      }
      return (width, height)
    }
  }

  extension PlatformDefaults {
    /// macOS's `ImageMetadataProbing` default — `ImageIO`-backed, byte-
    /// identical to the code this replaced. See `MacImageMetadataProbe`.
    public static var imageMetadataProbe: any ImageMetadataProbing {
      MacImageMetadataProbe()
    }
  }
#else
  extension PlatformDefaults {
    /// The non-Apple `ImageMetadataProbing` default — a real (not a
    /// no-op) portable implementation, since header parsing needs no
    /// platform-specific framework. See `PortableImageHeaderProbe`'s doc
    /// comment for exactly which formats it covers.
    public static var imageMetadataProbe: any ImageMetadataProbing {
      PortableImageHeaderProbe()
    }
  }
#endif
