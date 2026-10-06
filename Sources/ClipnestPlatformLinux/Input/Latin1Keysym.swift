import Foundation

/// X11 keysym values for the Latin-1 range (`0x20...0xFF`) are defined to
/// equal the character's own Unicode code point — a fixed, documented part
/// of the X11 keysym encoding (`X11/keysymdef.h`'s Latin-1 block: every
/// entry in that range is literally `#define XK_<name> 0x0<codepoint-hex>`,
/// e.g. `XK_v` is `0x0076` — the same as `U+0076`).
///
/// This lets `X11KeyboardLayoutResolver` compute the keysym for the ASCII
/// letters this stack ever needs (`v`) without linking `keysymdef.h` (not
/// exposed by `CXlib`'s `shim.h`, which only pulls in
/// `Xlib.h`/`Xatom.h`/`Xfixes.h`/`XTest.h`) and without a live-display round
/// trip through `XStringToKeysym`.
public enum Latin1Keysym {
  /// - Returns: the X11 keysym for `character`, or `nil` if it falls
  ///   outside the Latin-1 keysym range this stack relies on (every
  ///   character this module is ever asked to resolve — `v` — is within
  ///   it). `nil` here means "don't guess," matching
  ///   `KeyboardLayoutResolving`'s contract.
  public static func keysym(for character: Character) -> UInt32? {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
      (0x20...0xFF).contains(scalar.value)
    else { return nil }
    return scalar.value
  }
}
