// TextRecognizing.swift
//
// T-OCR1: abstraction over on-device text recognition for a captured
// image's raw bytes. `ClipboardMonitor` depends on this protocol, not on
// `Vision` directly — mirrors `PasteboardReading`/`EventSynthesizing`'s
// injectable-protocol pattern (coding-standards.md's testing rules: no real
// system-framework call — Vision included — from `ClipnestCoreTests`; tests
// inject a fake conformance instead). `VisionTextRecognizer.swift` is the
// production implementation.

import Foundation

/// Recognizes text in a captured image's raw bytes, entirely on-device — no
/// network call is ever involved (Vision's text recognizer requires none),
/// matching this codebase's "local-only, always" privacy must.
public protocol TextRecognizing: Sendable {
  /// Recognizes text in `imageData` — the same raw bytes `ClipItem`'s
  /// `.image` blob stores (PNG/TIFF, as captured by `PasteboardReader`) —
  /// at the requested `quality` (T-OCR8: user-configurable Fast/Accurate,
  /// see `TextRecognitionQuality`'s doc comment for the trade-off).
  /// `ClipboardMonitor` reads its `textRecognitionQualityProvider` fresh
  /// for every capture and passes the result straight through here, so a
  /// setting change takes effect on the very next copy with no
  /// `ClipboardMonitor`/recognizer recreation needed.
  ///
  /// Returns `nil` on failure, when `imageData` is an image this recognizer
  /// declines to process (e.g. it exceeds a size ceiling), or when no text
  /// is found — never throws, so a recognition failure can never surface as
  /// a capture failure (see `ClipboardMonitor`'s OCR wiring, which treats
  /// recognition as strictly best-effort and never blocks/fails capture on
  /// its account).
  func recognizeText(in imageData: Data, quality: TextRecognitionQuality) async -> String?
}
