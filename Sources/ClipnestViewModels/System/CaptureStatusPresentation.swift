// CaptureStatusPresentation.swift
//
// T-PAUSEICON1: the one place that maps "is capture paused?" to the words the
// status icon shows. macOS (menu-bar accessibility label) and Linux
// (StatusNotifierItem ToolTip) both read this, so the two can never disagree.
// A paused app loses history silently, so the icon itself must say so.

public struct CaptureStatusPresentation: Equatable, Sendable {
  public static let appName = "Clipnest"
  public static let pausedSuffix = "capture paused"

  public let isPaused: Bool

  public init(isPaused: Bool) {
    self.isPaused = isPaused
  }

  /// Accessibility label for the status icon: "Clipnest" / "Clipnest — capture paused".
  public var accessibilityLabel: String {
    isPaused ? "\(Self.appName) — \(Self.pausedSuffix)" : Self.appName
  }

  /// Tray tooltip body line; empty when capturing normally.
  public var tooltipDescription: String {
    isPaused ? "Capture paused — copies are not being saved" : ""
  }
}
