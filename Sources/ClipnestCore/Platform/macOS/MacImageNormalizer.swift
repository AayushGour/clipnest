#if os(macOS)
  import CoreGraphics
  import Foundation
  import ImageIO
  import UniformTypeIdentifiers

  /// Real, `ImageIO`-based `ImageNormalizing` implementation: decodes
  /// arbitrary image bytes and re-encodes them as TIFF, the format virtually
  /// every macOS app expects for a pasted image regardless of the original
  /// format.
  ///
  /// Extracted verbatim from `Paster`'s former private `normalizedToTIFF`
  /// static method (T-PERF1) — see `ImageNormalizing`
  /// (`Sources/ClipnestCore/Paste/Paster.swift`) for the protocol this
  /// implements and `Paster.paste(_:targetingFrontmostApp:)`'s `.image` case
  /// for how it's invoked (off-main, via `Task.detached(priority: .utility)`).
  public struct MacImageNormalizer: ImageNormalizing {
    public init() {}

    /// T-PERF1: decodes `data` (captured as PNG or TIFF — see
    /// `PasteboardReader.imagePasteboardTypes`) and re-encodes it as TIFF,
    /// entirely via `ImageIO`'s C API (never `NSImage`/`NSBitmapImageRep`) so
    /// it's safe to call from the `Task.detached` background task
    /// `Paster.paste(_:targetingFrontmostApp:)`'s `.image` case runs this on.
    /// Returns `nil` on any decode/encode failure (e.g. undecodable bytes) —
    /// the caller turns that into `PasteError.invalidImageData`, same
    /// contract the previous `NSImage(data:)?.tiffRepresentation`
    /// implementation had.
    ///
    /// Using `ImageIO` (`CGImageSource`/`CGImageDestination`) instead of
    /// `NSImage(data:)?.tiffRepresentation`: `NSImage` is not documented
    /// thread-safe for every operation, and this runs off `@MainActor` by
    /// design — `ImageIO`'s C API is a pure, thread-safe decode/encode with
    /// no such caveat. No force-unwrap: undecodable bytes (or an encode
    /// failure) return `nil` instead of crashing, per coding-standards.md —
    /// same contract `PasterTests.invalidImageDataThrowsBeforeAnyWrite`
    /// already verifies.
    public func normalizedForPaste(_ data: Data) -> (data: Data, mediaType: ClipMediaType)? {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        return nil
      }
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output, UTType.tiff.identifier as CFString, 1, nil)
      else {
        return nil
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return (output as Data, .tiff)
    }
  }

  extension PlatformDefaults {
    /// The production `ImageNormalizing` on macOS. See `PlatformDefaults`'s
    /// own doc comment for why this is a static member here rather than a
    /// literal default-argument value in `Paster.swift`.
    public static var imageNormalizer: any ImageNormalizing { MacImageNormalizer() }
  }
#endif
