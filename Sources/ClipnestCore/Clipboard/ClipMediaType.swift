import Foundation

/// Platform-neutral stand-in for `NSPasteboard.PasteboardType`.
///
/// On Apple platforms this is a plain `typealias` — NOT a wrapper — to
/// `NSPasteboard.PasteboardType` itself. That's the whole trick that makes
/// this a zero-test-edit refactor on macOS: every call site, every protocol
/// witness (`extension NSPasteboard: PasteboardReading`, etc.), and every
/// existing test fake that already speaks `NSPasteboard.PasteboardType`
/// keeps compiling untouched, because it's literally the same type, not a
/// distinct one that merely looks similar.
///
/// On non-Apple platforms (the Linux port) there is no `NSPasteboard`, so
/// `ClipMediaType` becomes its own minimal `RawRepresentable` wrapper around
/// the same raw UTI strings AppKit uses.
#if os(macOS)
  import AppKit
  public typealias ClipMediaType = NSPasteboard.PasteboardType
#else
  public struct ClipMediaType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
      self.rawValue = rawValue
    }
  }

  extension ClipMediaType {
    /// Mirrors `NSPasteboard.PasteboardType.string`'s raw UTI — verified
    /// against the AppKit SDK, not guessed.
    public static let string = ClipMediaType("public.utf8-plain-text")
    /// Mirrors `NSPasteboard.PasteboardType.rtf`'s raw UTI.
    public static let rtf = ClipMediaType("public.rtf")
    /// Mirrors `NSPasteboard.PasteboardType.png`'s raw UTI.
    public static let png = ClipMediaType("public.png")
    /// Mirrors `NSPasteboard.PasteboardType.tiff`'s raw UTI.
    public static let tiff = ClipMediaType("public.tiff")
    /// Mirrors `NSPasteboard.PasteboardType.fileURL`'s raw UTI.
    public static let fileURL = ClipMediaType("public.file-url")
  }
#endif

// Declared on both platforms as a plain extension on `ClipMediaType` — on
// macOS that's an extension on the AppKit struct `NSPasteboard.PasteboardType`
// itself (not a new conformance), so swift-format's `AvoidRetroactiveConformances`
// rule has nothing to fire on.
extension ClipMediaType {
  /// The `org.nspasteboard` marker apps set to say "don't record this"
  /// (password managers, etc). See `PrivacyFilter.concealedPasteboardType`.
  public static let concealed = ClipMediaType("org.nspasteboard.ConcealedType")

  /// The `org.nspasteboard` marker apps set to say "this is short-lived,
  /// don't record it" (e.g. an OTP that's about to be overwritten). See
  /// `PrivacyFilter.transientPasteboardType`.
  public static let transient = ClipMediaType("org.nspasteboard.TransientType")
}
