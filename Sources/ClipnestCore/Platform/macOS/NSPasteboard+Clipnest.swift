import Foundation

#if os(macOS)
  import AppKit

  /// Moved verbatim from `Clipboard/PasteboardReader.swift` by the Linux
  /// port (P2-A), wrapped in `#if os(macOS)` — `NSPasteboard` doesn't exist
  /// off Apple platforms.
  extension NSPasteboard: PasteboardReading {
    public var availableTypes: [NSPasteboard.PasteboardType] {
      types ?? []
    }
  }

  /// Moved verbatim from `Clipboard/ClipboardMonitor.swift` by the Linux
  /// port (P2-A), wrapped in `#if os(macOS)`.
  extension NSPasteboard: MonitoredPasteboard {}

  extension PlatformDefaults {
    /// macOS's `MonitoredPasteboard` default — the real system pasteboard.
    public static var monitoredPasteboard: any MonitoredPasteboard {
      NSPasteboard.general
    }
  }
#else
  extension PlatformDefaults {
    /// The non-Apple `MonitoredPasteboard` default. See
    /// `NullMonitoredPasteboard`'s doc comment.
    public static var monitoredPasteboard: any MonitoredPasteboard {
      NullMonitoredPasteboard()
    }
  }
#endif
