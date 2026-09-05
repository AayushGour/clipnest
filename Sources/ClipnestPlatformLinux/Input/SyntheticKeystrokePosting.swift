import Foundation

/// Posts a modifier-chorded key press: every modifier down (in a
/// consistent order), the base key down then up, then every modifier up in
/// reverse — mirroring macOS's `SyntheticKeystroke.postCommandModified`
/// (`Sources/ClipnestCore/Platform/macOS/CGEventSynthesizer.swift`), which
/// is the ONE place that builds and posts a modified keystroke on that
/// platform so a fix only has to be made once.
///
/// Each backend (`UInputEventSynthesizer`, `XTestEventSynthesizer`) is its
/// own "one place" for its own posting mechanism, so a future ⌘C-equivalent
/// caller (e.g. a Linux clipboard-selection replacer, out of this module's
/// scope) reuses the same backend instance's `post(_:)` instead of
/// hand-rolling a second uinput/XTEST call site.
///
/// Synchronous (not `async`, not `throws`) to mirror
/// `EventSynthesizing.synthesizeCommandV`'s own synchronous, throwing
/// shape — callers translate a `false` return into
/// `PasteError.eventPostFailed`.
public protocol SyntheticKeystrokePosting: Sendable {
  /// - Returns: `false` if the chord's key could not be resolved (layout
  ///   mapping failed — see `KeyboardLayoutResolving`), the D16/D39
  ///   modifier-release wait timed out, or the underlying backend call
  ///   failed; `true` once every event described above was posted.
  @discardableResult
  func post(_ chord: KeyChord) -> Bool
}
