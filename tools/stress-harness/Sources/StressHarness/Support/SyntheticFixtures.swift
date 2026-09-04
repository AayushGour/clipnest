// SyntheticFixtures.swift
//
// Small, deterministic non-image payloads (text/RTF/link/file) used to mix
// kinds during throughput stress, plus deliberately-broken image bytes for
// the failure-injection scenario. None of this touches the real pasteboard
// or the real Clipnest store.
import Foundation

enum SyntheticFixtures {
  static func text(_ index: Int) -> String {
    "Stress item #\(index) — \(UUID().uuidString) — " + String(repeating: "lorem ipsum ", count: 20)
  }

  static func link(_ index: Int) -> String {
    "https://example.com/stress/\(index)/\(UUID().uuidString)"
  }

  static func filePath(_ index: Int) -> String {
    "file:///tmp/stress-harness/file-\(index)-\(UUID().uuidString).txt"
  }

  /// Minimal well-formed RTF, unique per `index` so each produces a distinct
  /// `contentHash` (mirrors `PasteboardReader.readRichText`'s expectations —
  /// valid `.rtf` bytes, parseable by `NSAttributedString`).
  static func rtf(_ index: Int) -> Data {
    let text = "Rich stress item #\(index) \(UUID().uuidString)"
    let rtfString = "{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Helvetica;}} \\f0 \(text)}"
    return Data(rtfString.utf8)
  }

  /// Bytes that look nothing like any image format `PasteboardReader`/
  /// `VisionTextRecognizer` understands — for the failure-injection
  /// scenario's "corrupt image bytes" case. Must never crash either layer;
  /// both must degrade to "no image" gracefully.
  static func garbageImageBytes(byteCount: Int = 4096) -> Data {
    Data((0..<byteCount).map { UInt8(($0 * 37 + 11) % 256) })
  }

  /// A real TIFF header followed by truncated/garbage body — decodes far
  /// enough to pass an initial magic-byte sniff but fails full decode, a
  /// different failure mode than pure garbage (exercises `NSImage(data:)`/
  /// `CGImageSourceCreateWithData`'s "recognized format, corrupt payload"
  /// path rather than "unrecognized format" path).
  static func truncatedTIFFBytes(from realImage: Data, keepBytes: Int = 200) -> Data {
    realImage.prefix(min(keepBytes, realImage.count))
  }
}
