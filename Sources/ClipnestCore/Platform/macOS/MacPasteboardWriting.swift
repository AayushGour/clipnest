#if os(macOS)
  import AppKit
  import ApplicationServices
  import Foundation

  // `PasteboardWriting` refines `Sendable`, but `NSPasteboard` is an AppKit type
  // declared in another module, so Swift 6 requires the Sendable conformance be
  // spelled out as `@retroactive @unchecked` in a standalone extension. NSPasteboard
  // is a thread-safe system singleton, so `@unchecked` is sound here.
  // The retroactive conformance is required by the language here, so silence the
  // lint rule that would otherwise flag it.
  // swift-format-ignore: AvoidRetroactiveConformances
  extension NSPasteboard: @retroactive @unchecked Sendable {}

  extension NSPasteboard: PasteboardWriting {
    public func writeString(_ string: String, forType type: NSPasteboard.PasteboardType) {
      clearContents()
      setString(string, forType: type)
    }

    public func writeData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
      clearContents()
      setData(data, forType: type)
    }

    public func writeRichText(rtf: Data, plain: String) {
      clearContents()
      setData(rtf, forType: .rtf)
      setString(plain, forType: .string)
    }

    public func writeFileURL(_ url: URL) {
      clearContents()
      // `as NSURL`: `writeObjects` takes `NSPasteboardWriting`, which `NSURL`
      // conforms to and the Swift-native `URL` value type does not.
      writeObjects([url as NSURL])
    }
  }

  extension PlatformDefaults {
    /// The production `PasteboardWriting` on macOS — the real system
    /// pasteboard. See `PlatformDefaults`'s own doc comment for why this is a
    /// static member here rather than a literal default-argument value in
    /// `Paster.swift`.
    public static var pasteboard: any PasteboardWriting { NSPasteboard.general }

    /// The production Accessibility-granted check on macOS. Injected rather
    /// than called directly by `Paster` so tests never touch the real
    /// permission — see coding-standards.md's testing rules and its
    /// "Accessibility is optional, not required" privacy must.
    public static var isAccessibilityGranted: @Sendable () -> Bool { { AXIsProcessTrusted() } }
  }
#endif
