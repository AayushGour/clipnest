// TextRecognitionQuality.swift
//
// T-OCR8: the user-facing knob for on-device text recognition speed vs.
// accuracy, added after real-world testing showed `.fast` (T-OCR1's
// hardcoded choice) mangling digits/letters ("l." for "1."), punctuation
// ("Settings_" for "Settings..."), and arrows on a real screenshot, while
// `.accurate` read all three correctly (at ~6.7x the per-image latency —
// 154ms vs 23ms on a 2222x1244 screenshot downscaled to `VisionTextRecognizer
// .maxDownscaledDimension`). Neither level can read keyboard glyphs like
// ⌘ ⌥ ⇧ — those fall outside Vision's recognized character set entirely,
// independent of this setting; that's accepted, not a gap this type papers
// over.
//
// Deliberately NOT `Vision.VNRequestTextRecognitionLevel` reused directly —
// coding-standards.md's module layout keeps `Vision` behind
// `ClipnestCore/OCR/`; `SettingsStore` and the Settings UI (`ClipnestApp`
// layer) must never `import Vision` just to store/display a quality choice.
// `VisionTextRecognizer` is the one place that maps this to the real Vision
// enum (see its `recognitionLevel(for:)`).
//
// `String, CaseIterable` (not just `Sendable`) mirrors
// `SettingsStore.RetentionMode`'s shape exactly — both are small,
// UserDefaults-persisted choice enums stored by `rawValue`.
public enum TextRecognitionQuality: String, CaseIterable, Sendable {
  /// Low-latency recognition pass. Quicker per image, but confuses
  /// visually-similar characters (digits vs. letters) and drops most
  /// punctuation/arrows.
  case fast
  /// Higher-latency recognition pass that also applies language
  /// correction. Correctly reads punctuation, digits, and arrows that
  /// `.fast` mixes up. The default (see `SettingsStore
  /// .textRecognitionQuality`) — most screenshots are captured far less
  /// often than, say, a keystroke, so the added latency is rarely felt,
  /// while the accuracy gap is very visible once a user actually searches.
  case accurate
}
