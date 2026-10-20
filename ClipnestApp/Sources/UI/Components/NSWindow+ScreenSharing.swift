// NSWindow+ScreenSharing.swift
//
// T-SHAREEXCL1: one place that excludes a Clipnest window from screen
// sharing/recording, used by every window that renders clipboard contents.

import AppKit

extension NSWindow {
  /// Asks the window server to omit this window from screen sharing and
  /// recording (`sharingType = .none`). Clipboard contents can include
  /// secrets (passwords, tokens), so the picker and the item preview should
  /// not leak into a shared screen or a recording.
  ///
  /// Best effort, not a guarantee: `.none` is honored by legacy capture paths
  /// (CGWindowList-based capture, QuickTime, most conferencing apps), but on
  /// macOS 15+ ScreenCaptureKit-based capture may still include such windows
  /// in some modes.
  func excludeFromScreenSharing() {
    sharingType = .none
  }
}
