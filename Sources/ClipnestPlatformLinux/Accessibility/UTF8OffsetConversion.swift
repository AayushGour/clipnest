import Foundation

/// AT-SPI's `Text` interface reports selection/read offsets as Unicode
/// CODE-POINT (scalar) offsets — matching Swift's `unicodeScalars` view,
/// NOT `Character` (extended grapheme clusters): an emoji-with-modifier or
/// a combining-mark sequence is ONE `Character` but multiple scalars, and
/// AT-SPI counts scalars.
///
/// `EditableText.InsertText`'s `length` argument, however, is documented
/// as a BYTE count of the UTF-8–encoded `text` argument, not a character
/// or scalar count — while `position` is a character/scalar OFFSET. Mixing
/// the two up (e.g. passing `text.count`) silently corrupts non-ASCII
/// snippet bodies: exactly the "classic off-by-N" this task calls out.
enum UTF8OffsetConversion {
  /// The `length` `EditableText.InsertText` expects for `text` — its UTF-8
  /// byte count, never its character/scalar count.
  static func utf8ByteCount(of text: String) -> Int32 {
    Int32(clamping: text.utf8.count)
  }

  /// The number of AT-SPI offset units `text` occupies once inserted — its
  /// Unicode SCALAR count, the same unit `Text`/`EditableText` offsets
  /// (`selection.start`/`selection.end`, `InsertText`'s `position`) already
  /// use. Verified against a real `at-spi2-core` bus, not assumed: a
  /// `dbus-monitor` capture of a live `EditableText.InsertText` call showed
  /// `Text.CharacterCount` advancing by exactly this count (not the UTF-16
  /// code-unit count, which a supplementary-plane character like an emoji
  /// would double, and not the extended-grapheme-cluster/`Character` count,
  /// which a base+combining-mark sequence would undercount by one per
  /// combining mark) — see `ATSPITextAccessor.replaceSelectedText`'s write
  /// re-verification for the call site.
  static func scalarCount(of text: String) -> Int32 {
    Int32(clamping: text.unicodeScalars.count)
  }

  /// The `String.Index` `scalarOffset` Unicode scalars into `text`, or
  /// `nil` if out of range.
  static func stringIndex(atScalarOffset scalarOffset: Int, in text: String) -> String.Index? {
    guard scalarOffset >= 0 else { return nil }
    let scalars = text.unicodeScalars
    return scalars.index(scalars.startIndex, offsetBy: scalarOffset, limitedBy: scalars.endIndex)
  }

  /// The substring of `text` between two AT-SPI scalar offsets, or `nil`
  /// if either offset is out of range or `start > end`.
  static func substring(in text: String, startScalarOffset: Int, endScalarOffset: Int) -> String? {
    guard startScalarOffset <= endScalarOffset,
      let start = stringIndex(atScalarOffset: startScalarOffset, in: text),
      let end = stringIndex(atScalarOffset: endScalarOffset, in: text)
    else { return nil }
    return String(text.unicodeScalars[start..<end])
  }
}
