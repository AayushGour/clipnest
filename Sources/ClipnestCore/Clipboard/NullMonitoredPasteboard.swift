import Foundation

/// P2-A (Linux port): the non-Apple default `MonitoredPasteboard`
/// conformance. Reports no available types and a `changeCount` fixed at 0
/// (so `ClipboardMonitor.checkNow()`'s "did anything change" guard never
/// fires) — "never used in production" (`PlatformDefaults.swift`'s
/// documented convention for portable no-op defaults): the Linux
/// composition root always injects a real desktop-clipboard backend (e.g.
/// GTK's `GtkClipboard`/X11 selection ownership) for this parameter, this
/// exists only so `ClipboardMonitor.init`'s `pasteboard` parameter has
/// *some* non-Apple default to compile against.
public struct NullMonitoredPasteboard: MonitoredPasteboard {
  public init() {}

  public var availableTypes: [ClipMediaType] { [] }
  public var changeCount: Int { 0 }

  public func string(forType type: ClipMediaType) -> String? { nil }
  public func data(forType type: ClipMediaType) -> Data? { nil }
}
